defmodule Laev.MAL do
  @moduledoc """
  Anime list scrobbling, over the `myanimelist` package.

  Laev carried its own MyAnimeList client until the package was published; the
  protocol half of it — PKCE with MAL's plain challenge, the token refresh, the
  `num_watched_episodes` spelling that MAL's responses do not use — now lives
  there, and laev and roki share one copy of it.

  What stays here is what is laev's rather than MyAnimeList's: where a token
  lives (`Laev.MAL.Tokens`, per scope), the local listener the browser is
  redirected to, and the shapes the rest of laev reads — `list/1`'s entries,
  `anime/1`, and `set_progress/3` deciding that the last episode finishes a
  show.

  Everything returns values, never raises.
  """

  alias MyAnimeList.{Client, Token}
  alias Laev.MAL.Tokens

  @redirect "http://localhost:8723/callback"

  # The user's own list, with the node fields laev needs on it: how long an
  # episode runs and how many there are, which is where anime hours come from.
  # The package's `list_statuses/3` keeps only the list_status object, so this
  # request is still laev's own — see the task filed about it.
  @base "https://api.myanimelist.net/v2"

  # ── config / state ────────────────────────────────────────────────

  def client_id, do: Laev.Scope.get(:mal_client_id)
  def client_secret, do: Laev.Scope.get(:mal_client_secret)
  def configured?, do: MyAnimeList.configured?(client_id())

  @doc "True once the user has logged in (a token is stored)."
  def authenticated?, do: Tokens.exists?()

  def redirect_uri, do: @redirect

  # Everything the package needs to speak for this user.
  defp client do
    %Client{client_id: client_id(), client_secret: client_secret(), redirect_uri: @redirect}
  end

  # ── OAuth ─────────────────────────────────────────────────────────

  @doc "A PKCE verifier (also used verbatim as the plain challenge)."
  def new_verifier, do: MyAnimeList.new_code_verifier()

  @doc "The MAL authorize URL to open in the browser."
  def authorize_url(state, verifier), do: MyAnimeList.authorize_url(client(), state, verifier)

  @doc "Exchange an auth code for tokens and persist them."
  def exchange_code(code, verifier) do
    case MyAnimeList.exchange_code(client(), code, verifier) do
      {:ok, %Token{} = token} ->
        Tokens.put_token(:me, token)
        {:ok, %{access_token: token.access_token, refresh_token: token.refresh_token}}

      error ->
        error
    end
  end

  @doc "Forget the stored tokens (logout)."
  def logout, do: Tokens.delete_token(:me)

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
        {:ok, _} -> "<h2>Laev is linked to MyAnimeList ✓</h2><p>You can close this tab and return to the terminal.</p>"
        _ -> "<h2>Login failed</h2><p>Return to the terminal and try again.</p>"
      end

    :gen_tcp.send(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" <> body)
    :gen_tcp.close(conn)
    result
  end

  # A valid access token, refreshed if it is within a minute of expiry. nil
  # when not logged in or the refresh fails. A refreshed token is persisted
  # here, because the package hands one back rather than storing it.
  defp access_token do
    with %Token{} = stored <- Tokens.get_token(:me),
         {:ok, %Token{} = fresh} <- MyAnimeList.ensure_fresh(client(), stored) do
      if fresh != stored, do: Tokens.put_token(:me, fresh)
      fresh.access_token
    else
      _ -> nil
    end
  end

  # ── anime list ────────────────────────────────────────────────────

  @doc "The logged-in user's MAL username, or nil."
  def username do
    case access_token() do
      at when is_binary(at) -> MyAnimeList.username(at)
      _ -> nil
    end
  end

  @doc """
  The user's list status for an anime: `%{status, episodes_watched, score}`
  or nil (not on list / not logged in).
  """
  # One anime, one request. The package has `my_progress/4` (the count alone)
  # and `list_statuses/3` (everybody's, paged a thousand at a time) and nothing
  # in between — and this is called once per episode watched, so asking for the
  # whole list to read one row of it is not an option.
  def list_status(mal_id) do
    with at when is_binary(at) <- access_token(),
         {:ok, %{status: 200, body: %{"my_list_status" => status}}} <-
           Req.get("#{@base}/anime/#{mal_id}",
             headers: [{"authorization", "Bearer #{at}"}],
             params: [fields: "my_list_status"],
             retry: false,
             receive_timeout: 15_000
           ) do
      %{
        status: status["status"],
        episodes_watched: status["num_episodes_watched"] || 0,
        score: status["score"] || 0
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
  Every anime on the user's list, newest fields and all: `[%{mal_id:, title:,
  status:, episodes_watched:, episodes:, episode_seconds:, kind:}]`.

  Paged a thousand at a time — a long-standing list runs to several hundred
  entries, and MAL will hand them all over, just not at once. `nsfw: true`
  because a list laev imports has to be the list the user actually has.
  """
  def list(report \\ fn _line -> :ok end) do
    case access_token() do
      at when is_binary(at) -> pages(start_url(), at, [], report)
      _ -> {:error, :not_linked}
    end
  end

  defp start_url do
    "#{@base}/users/@me/animelist?" <>
      URI.encode_query(%{
        "fields" => "list_status,num_episodes,average_episode_duration,media_type",
        "limit" => "1000",
        "nsfw" => "true"
      })
  end

  defp pages(url, at, acc, report) do
    case Req.get(url,
           headers: [{"authorization", "Bearer #{at}"}],
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data} = body}} ->
        acc = acc ++ Enum.flat_map(data, &entry/1)
        report.("#{length(acc)} anime…")

        case get_in(body, ["paging", "next"]) do
          next when is_binary(next) -> pages(next, at, acc, report)
          _ -> {:ok, acc}
        end

      {:ok, %{status: status}} ->
        {:error, {:mal, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp entry(%{"node" => %{"id" => id} = node, "list_status" => status}) when is_integer(id) do
    [
      %{
        mal_id: id,
        title: node["title"],
        kind: node["media_type"],
        episodes: node["num_episodes"],
        # MAL knows how long an episode of this anime runs, which TMDB often
        # doesn't for anime — it rides along so an import can say what it is
        # claiming in hours, not just in episode counts.
        episode_seconds: node["average_episode_duration"],
        status: status["status"],
        episodes_watched: status["num_episodes_watched"] || 0,
        score: status["score"] || 0,
        # When you last touched this anime on MAL — which is when you last
        # watched an episode of it. It is what puts the thing you are in the
        # middle of at the top of a list instead of somewhere alphabetical.
        updated: unix(status["updated_at"])
      }
    ]
  end

  defp entry(_other), do: []

  @doc """
  One anime, as laev needs to describe it: `%{title:, episodes:, seconds:,
  status:, score:}` — or nil. Public data, so it works logged out too.
  """
  def anime(mal_id) when is_integer(mal_id) do
    fields = "title,num_episodes,average_episode_duration,my_list_status"

    with {:ok, %{status: 200, body: %{"title" => title} = body}} <- get_anime(mal_id, fields) do
      %{
        title: title,
        episodes: body["num_episodes"],
        seconds: body["average_episode_duration"],
        status: get_in(body, ["my_list_status", "status"]),
        score: get_in(body, ["my_list_status", "score"]),
        updated: unix(get_in(body, ["my_list_status", "updated_at"]))
      }
    else
      _ -> nil
    end
  end

  def anime(_mal_id), do: nil

  # The one request that works with either credential: a user token when there
  # is one (so my_list_status comes back), the bare client id when there isn't.
  #
  # Not the package's `get/4`: that is client-id only, and it normalizes the
  # answer into its own shape, which has no room for *your* status and score.
  # Those are the point of asking here.
  defp get_anime(mal_id, fields) do
    case access_token() do
      at when is_binary(at) ->
        Req.get("#{@base}/anime/#{mal_id}",
          headers: [{"authorization", "Bearer #{at}"}],
          params: [fields: fields],
          retry: false,
          receive_timeout: 15_000
        )

      _ ->
        Req.get("#{@base}/anime/#{mal_id}",
          headers: [{"x-mal-client-id", client_id() || ""}],
          params: [fields: fields],
          retry: false,
          receive_timeout: 15_000
        )
    end
  end

  @doc """
  Record progress: set watched count and status. Never regresses a higher
  count already on MAL. `total` (episode count, optional) decides whether
  finishing marks the show *completed*.

  Adds the anime to the list if it isn't on it — MAL's PATCH is an upsert, so
  starting something you never planned to watch just appears as *watching*.

  Returns `{:ok, fields}` | {:error, reason} | :skip.
  """
  def set_progress(mal_id, episode, total \\ nil) do
    with at when is_binary(at) <- access_token() do
      current = list_status(mal_id)
      count = max(episode, (current && current.episodes_watched) || 0)
      fields = progress_fields(count, total)

      # An anime not on the list can't take a full update: MAL's PATCH only
      # creates an entry when the form is a bare status, and answers a full
      # form with 400 "should not contain extra fields" — so something you
      # start watching out of nowhere is added first, then counted.
      if current == nil, do: patch(mal_id, at, %{status: "watching"})

      # The fields come back so the caller knows what the list now says — the
      # count it settled on and whether that finished the anime. Guessing either
      # would mean asking MAL again for something it was just told.
      case patch(mal_id, at, fields) do
        :ok -> {:ok, fields}
        other -> other
      end
    else
      _ -> :skip
    end
  end

  @doc """
  What to send for "watched episode N of M": the count, the status, and a finish
  date on the episode that completes it.

  The last episode is the whole point — a list that still says *watching* after
  the finale is a list you have to go and tidy by hand — so reaching the episode
  count flips the entry to completed and dates it today. An anime whose total
  MAL doesn't know (a running series, a long-form shounen) stays *watching*,
  because nothing here can tell when it ends.
  """
  # The spelling trap — the request field is `num_watched_episodes` while MAL's
  # *responses* say `num_episodes_watched`, and sending the response spelling
  # is a 400 that used to be swallowed silently — is the package's problem now.
  def progress_fields(count, total), do: MyAnimeList.progress_fields(:anime, count, total)

  @doc """
  Set the list status of an anime — "watching", "on_hold", "completed",
  "dropped", "plan_to_watch" — without touching the episode count.
  """
  def set_status(mal_id, status) when is_binary(status) do
    case access_token() do
      at when is_binary(at) -> patch(mal_id, at, %{status: status})
      _ -> :skip
    end
  end

  @doc "Set the user's score (1–10) for an anime."
  def rate(mal_id, score) when score in 0..10 do
    case access_token() do
      at when is_binary(at) -> unwrap(MyAnimeList.rate(:anime, at, mal_id, score))
      _ -> :skip
    end
  end

  @doc """
  An anime's opening and ending songs, as `%{openings: [...], endings: [...]}`.
  Public data, so no login is needed.
  """
  def themes(mal_id) when is_integer(mal_id) do
    case MyAnimeList.themes(mal_id, client_id() || "") do
      {:ok, themes} -> themes
      _ -> %{openings: [], endings: []}
    end
  end

  defp patch(mal_id, at, fields),
    do: unwrap(MyAnimeList.update_list_status(:anime, at, mal_id, fields))

  # Laev's callers only ever asked whether it went through.
  defp unwrap({:ok, _body}), do: :ok
  defp unwrap(error), do: error

  defp unix(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _offset} -> DateTime.to_unix(at)
      _ -> nil
    end
  end

  defp unix(_stamp), do: nil
end
