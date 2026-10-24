defmodule Laev.Setup do
  @moduledoc """
  Setting laev up for the first time, in one call.

  The terminal has a wizard for this and a web interface needs the same thing,
  so the thing itself lives here and both ask for it. What it does, in order:
  check every key against the service it belongs to, make a laev key, connect
  with it so the keys are carried to the user's other devices, save them, and
  sync once.

  Nothing is left behind on failure. A half-configured laev is worse than an
  unconfigured one: it looks ready and then cannot play anything, and the reason
  is somewhere in a config file rather than on screen.
  """

  alias Laev.{Config, Settings, Sync}

  @doc """
  Set up from a map of keys, e.g.
  `%{"TMDB_API_KEY" => …, "RD_TOKEN" => …}`. Blanks are ignored.

  TMDB is required — nothing can be found without it — and so is one of
  Real-Debrid or TorBox, since nothing can be played without one. Each key is
  checked against its own service before anything is written, so a typo is an
  error here rather than a failure at the first film.

  `{:ok, %{key: laev_key, checked: […]}}` or `{:error, reason}`.
  """
  def first_run(keys) when is_map(keys) do
    keys = for {k, v} <- keys, (v = String.trim(v || "")) != "", into: %{}, do: {k, v}

    cond do
      not Map.has_key?(keys, "TMDB_API_KEY") ->
        {:error, :tmdb_key_required}

      not (Map.has_key?(keys, "RD_TOKEN") or Map.has_key?(keys, "TORBOX_API_KEY")) ->
        {:error, :debrid_key_required}

      true ->
        with :ok <- check_all(keys), do: create(keys)
    end
  end

  def first_run(_keys), do: {:error, :tmdb_key_required}

  @doc """
  A fresh laev key: `laev_<token>.<secret>`.

  The token half is what the server sees and addresses the document; the secret
  half never leaves the machine and encrypts the API keys that travel with it.
  """
  def generate_key do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "laev_#{token}.#{secret}"
  end

  @doc """
  Save a key only if its service accepts it.

  `{:ok, detail}` with what the service said about the account — the plan, the
  days left — or `{:error, reason}` with nothing saved. The point is that a
  rejected key never becomes the configured one.
  """
  def replace_key(key, value) when is_binary(key) do
    value = String.trim(value || "")

    with true <- value != "" or {:error, :empty},
         {:ok, detail} <- Settings.validate(key, value),
         :ok <- Settings.put(key, value) do
      {:ok, detail}
    else
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp check_all(keys) do
    Enum.find_value(keys, :ok, fn {key, value} ->
      case Settings.validate(key, value) do
        {:ok, _detail} -> nil
        {:error, reason} -> {:error, {key, reason}}
      end
    end)
  end

  defp create(keys) do
    laev_key = generate_key()
    previous = Config.file_value("LAEV_SYNC_TOKEN")

    result =
      with :ok <- carry_keys(),
           {:ok, _summary} <- Sync.connect(laev_key),
           :ok <- save_all(keys) do
        Sync.sync()
        {:ok, %{key: laev_key, checked: Map.keys(keys)}}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        roll_back(previous)
        {:error, reason}

      other ->
        roll_back(previous)
        {:error, other}
    end
  end

  # The keys travel with the laev key, which is the whole reason a second
  # device needs nothing but that one string.
  defp carry_keys do
    Config.write([{"LAEV_SYNC_KEYS", "on"}])
    Laev.Scope.set(:sync_keys, "on")
    :ok
  end

  defp save_all(keys) do
    Enum.reduce_while(keys, :ok, fn {key, value}, :ok ->
      case Settings.put(key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Whatever was there before, back as it was — including nothing.
  defp roll_back(previous) do
    if previous,
      do: Config.write([{"LAEV_SYNC_TOKEN", previous}]),
      else: Config.write([{"LAEV_SYNC_TOKEN", ""}])

    Laev.Scope.set(:sync_token, previous)
    :ok
  rescue
    _ -> :ok
  end
end
