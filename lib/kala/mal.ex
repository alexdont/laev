defmodule Kala.MAL do
  @moduledoc """
  MyAnimeList API v2 client — anime list scrobbling.

  OAuth is authorization-code + PKCE (MAL only supports the "plain" challenge,
  so verifier == challenge). The owner ships a `MAL_CLIENT_ID` (and secret if
  their app has one); each user authorizes their own account once via
  `kala mal login`, and the tokens live in `~/.kala/mal.json`, auto-refreshed.

  Everything returns values, never raises.
  """

  @base "https://api.myanimelist.net/v2"
  @auth "https://myanimelist.net/v1/oauth2/authorize"
  @token "https://myanimelist.net/v1/oauth2/token"
  @redirect "http://localhost:8723/callback"

  # ── config / state ────────────────────────────────────────────────

  def client_id, do: Application.get_env(:kala_app, :mal_client_id)
  def client_secret, do: Application.get_env(:kala_app, :mal_client_secret)
  def configured?, do: is_binary(client_id()) and client_id() != ""

  @doc "True once the user has logged in (a token is stored)."
  def authenticated?, do: File.exists?(token_path())

  def redirect_uri, do: @redirect

  defp token_path do
    dir = Application.get_env(:kala_app, :data_dir) || Path.join(System.user_home!(), ".kala")
    File.mkdir_p!(dir)
    Path.join(dir, "mal.json")
  end

  # ── OAuth ─────────────────────────────────────────────────────────

  @doc "A PKCE verifier (also used verbatim as the plain challenge)."
  def new_verifier, do: :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)

  @doc "The MAL authorize URL to open in the browser."
  def authorize_url(state, verifier) do
    @auth <>
      "?" <>
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id(),
        "state" => state,
        "code_challenge" => verifier,
        "code_challenge_method" => "plain",
        "redirect_uri" => @redirect
      })
  end

  @doc "Exchange an auth code for tokens and persist them."
  def exchange_code(code, verifier) do
    with {:ok, tokens} <-
           token_request(%{
             "grant_type" => "authorization_code",
             "code" => code,
             "code_verifier" => verifier,
             "redirect_uri" => @redirect
           }) do
      store_tokens(tokens)
      {:ok, tokens}
    end
  end

  defp token_request(params) do
    body =
      params
      |> Map.put("client_id", client_id())
      |> maybe_secret()

    case Req.post(@token, form: body, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        {:ok, %{access_token: at, refresh_token: b["refresh_token"], expires_in: b["expires_in"]}}

      {:ok, %{status: s, body: b}} ->
        {:error, {:mal, s, inspect(b)}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp maybe_secret(body) do
    case client_secret() do
      s when is_binary(s) and s != "" -> Map.put(body, "client_secret", s)
      _ -> body
    end
  end

  defp store_tokens(%{access_token: at, refresh_token: rt, expires_in: ei}) do
    data = %{
      "access_token" => at,
      "refresh_token" => rt,
      "expires_at" => System.os_time(:second) + (ei || 2_400_000)
    }

    File.write(token_path(), Jason.encode!(data))
  end

  @doc "Forget the stored tokens (logout)."
  def logout, do: File.rm(token_path())

  @doc """
  Run the full login: open the browser to MAL, wait for the redirect on the
  local listener, exchange the code. Returns {:ok, username} | {:error, reason}.
  `open_browser` is a 1-arg fn given the authorize URL.
  """
  def login(open_browser) do
    verifier = new_verifier()
    state = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    open_browser.(authorize_url(state, verifier))

    with {:ok, code} <- await_code(state),
         {:ok, _tokens} <- exchange_code(code, verifier) do
      {:ok, username() || "your account"}
    end
  end

  # One-shot HTTP listener for the OAuth redirect (http://localhost:8723/
  # callback?code=...&state=...). No web framework — a raw gen_tcp accept,
  # parse the query, reply with a small page, close. 3-minute timeout.
  defp await_code(expected_state) do
    case :gen_tcp.listen(8723, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, sock} ->
        result =
          case :gen_tcp.accept(sock, 180_000) do
            {:ok, conn} -> handle_conn(conn, expected_state)
            {:error, _} = e -> e
          end

        :gen_tcp.close(sock)
        result

      {:error, _} = e ->
        e
    end
  end

  defp handle_conn(conn, expected_state) do
    req =
      case :gen_tcp.recv(conn, 0, 10_000) do
        {:ok, data} -> data
        _ -> ""
      end

    result =
      with [_, query] <- Regex.run(~r/GET\s+\/callback\?(\S+)\s/, req),
           params = URI.decode_query(query),
           %{"code" => code, "state" => state} <- params,
           true <- state == expected_state do
        {:ok, code}
      else
        _ -> {:error, :bad_callback}
      end

    body =
      case result do
        {:ok, _} -> "<h2>Kala is linked to MyAnimeList ✓</h2><p>You can close this tab and return to the terminal.</p>"
        _ -> "<h2>Login failed</h2><p>Return to the terminal and try again.</p>"
      end

    :gen_tcp.send(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" <> body)
    :gen_tcp.close(conn)
    result
  end

  # A valid access token, refreshing if expired. nil when not logged in or the
  # refresh fails.
  defp access_token do
    with {:ok, body} <- File.read(token_path()),
         {:ok, %{"access_token" => at, "refresh_token" => rt, "expires_at" => exp}} <-
           Jason.decode(body) do
      if System.os_time(:second) < exp - 60 do
        at
      else
        case token_request(%{"grant_type" => "refresh_token", "refresh_token" => rt}) do
          {:ok, tokens} -> store_tokens(tokens) && tokens.access_token
          _ -> nil
        end
      end
    else
      _ -> nil
    end
  end

  # ── anime list ────────────────────────────────────────────────────

  @doc "The logged-in user's MAL username, or nil."
  def username do
    with at when is_binary(at) <- access_token(),
         {:ok, %{status: 200, body: %{"name" => name}}} <- get("/users/@me", at, fields: "name") do
      name
    else
      _ -> nil
    end
  end

  @doc """
  The user's list status for an anime: `%{status, episodes_watched, score}`
  or nil (not on list / not logged in).
  """
  def list_status(mal_id) do
    with at when is_binary(at) <- access_token(),
         {:ok, %{status: 200, body: %{"my_list_status" => ls}}} <-
           get("/anime/#{mal_id}", at, fields: "my_list_status") do
      %{
        status: ls["status"],
        episodes_watched: ls["num_episodes_watched"] || 0,
        score: ls["score"] || 0
      }
    else
      _ -> nil
    end
  end

  @doc "Episodes the user has watched of this anime on MAL (0 if unknown)."
  def episodes_watched(mal_id) do
    case list_status(mal_id) do
      %{episodes_watched: n} -> n
      _ -> 0
    end
  end

  @doc """
  Record progress: set watched count and status. Never regresses a higher
  count already on MAL. `total` (episode count, optional) decides whether
  finishing marks the show *completed*. Returns :ok | {:error, reason} | :skip.
  """
  def set_progress(mal_id, episode, total \\ nil) do
    with at when is_binary(at) <- access_token() do
      current = episodes_watched(mal_id)
      count = max(episode, current)

      status =
        cond do
          is_integer(total) and total > 0 and count >= total -> "completed"
          true -> "watching"
        end

      fields = %{num_episodes_watched: count, status: status}
      fields = if status == "completed", do: Map.put(fields, :finish_date, today()), else: fields

      patch(mal_id, at, fields)
    else
      _ -> :skip
    end
  end

  @doc "Set the user's score (1–10) for an anime."
  def rate(mal_id, score) when score in 0..10 do
    case access_token() do
      at when is_binary(at) -> patch(mal_id, at, %{score: score})
      _ -> :skip
    end
  end

  defp patch(mal_id, at, fields) do
    req =
      Req.new(
        method: :patch,
        url: "#{@base}/anime/#{mal_id}/my_list_status",
        headers: [{"authorization", "Bearer #{at}"}],
        form: fields,
        retry: false,
        receive_timeout: 15_000
      )

    case Req.request(req) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, {:mal, s}}
      {:error, e} -> {:error, e}
    end
  end

  defp get(path, at, params) do
    Req.get("#{@base}#{path}",
      headers: [{"authorization", "Bearer #{at}"}],
      params: params,
      retry: false,
      receive_timeout: 15_000
    )
  end

  defp today, do: Date.utc_today() |> Date.to_iso8601()
end
