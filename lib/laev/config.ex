defmodule Laev.Config do
  @moduledoc """
  Loads provider tokens and API keys into the app env.

  Sources, in order of precedence:

    1. Environment variables (`RD_TOKEN`, `TMDB_API_KEY`, …)
    2. `~/.config/laev/config` — plain `KEY=VALUE` lines, `#` comments,
       same key names as the environment variables.
  """

  @keys %{
    "RD_TOKEN" => :rd_token,
    "TORBOX_API_KEY" => :torbox_api_key,
    "TMDB_API_KEY" => :tmdb_key,
    "LAEV_LANG" => :lang,
    "LAEV_SUBS" => :subs_lang,
    "LAEV_MPV_ARGS" => :mpv_args,
    "LAEV_POSTERS" => :posters,
    "LAEV_SKIP" => :skip,
    "LAEV_AUTOPLAY" => :autoplay,
    "LAEV_DOWNLOAD_DIR" => :download_dir,
    "LAEV_LOGO_COLORS" => :logo_colors,
    "OPENSUBTITLES_API_KEY" => :opensubtitles_api_key,
    "OPENSUBTITLES_USERNAME" => :opensubtitles_username,
    "OPENSUBTITLES_PASSWORD" => :opensubtitles_password,
    "JACKETT_URL" => :jackett_url,
    "JACKETT_API_KEY" => :jackett_api_key,
    "JACKETT_INDEXER" => :jackett_indexer,
    "JIMAKU_API_KEY" => :jimaku_api_key,
    "MAL_CLIENT_ID" => :mal_client_id,
    "MAL_CLIENT_SECRET" => :mal_client_secret,
    "LAEV_MAL_SCROBBLE" => :mal_scrobble,
    "LAEV_SYNC_URL" => :sync_url,
    "LAEV_SYNC_TOKEN" => :sync_token,
    "LAEV_SYNC_AUTO" => :sync_auto,
    "LAEV_SYNC_LIVE" => :sync_live,
    "LAEV_SYNC_KEYS" => :sync_keys
  }

  @doc "The ENV_KEY => app-env-atom map for every configurable key."
  def keys, do: @keys

  # What travels with a laev key. Everything configurable except the sync
  # settings themselves — which are what bootstraps the restore, so carrying
  # them would be circular — and the two machine-specific ones, since another
  # computer has neither the same download directory nor the same mpv flags.
  @unsynced ~w(LAEV_SYNC_URL LAEV_SYNC_TOKEN LAEV_SYNC_AUTO LAEV_SYNC_LIVE LAEV_SYNC_KEYS
               LAEV_DOWNLOAD_DIR LAEV_MPV_ARGS)

  @doc "Config keys that a laev key carries between machines."
  def syncable_keys, do: Map.keys(@keys) -- @unsynced

  @doc "The currently-set syncable keys, as ENV_KEY => value."
  def export do
    for key <- syncable_keys(),
        value = Application.get_env(:laev_app, Map.fetch!(@keys, key)),
        value not in [nil, ""],
        into: %{},
        do: {key, value}
  end

  @doc """
  Write restored keys to the config file and into the running app, skipping
  anything that isn't a key laev recognises. Returns how many were applied.
  """
  def import_keys(map) when is_map(map) do
    pairs =
      for {key, value} <- map,
          key in syncable_keys(),
          is_binary(value),
          String.trim(value) != "",
          do: {key, value}

    if pairs != [] do
      write(pairs)
      for {key, value} <- pairs, do: Application.put_env(:laev_app, Map.fetch!(@keys, key), value)
    end

    length(pairs)
  end

  def import_keys(_), do: 0

  @doc """
  Upsert `KEY=VALUE` lines in the config file, leaving everything else — other
  keys, comments, ordering — as it was. The file holds credentials, so it is
  kept owner-only.
  """
  def write(pairs) do
    path = path()
    File.mkdir_p!(Path.dirname(path))

    lines =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n")
        _ -> ["# laev config — created by laev setup"]
      end

    updated =
      Enum.reduce(pairs, lines, fn {key, value}, acc ->
        line = "#{key}=#{value}"
        present? = Enum.any?(acc, &String.starts_with?(String.trim_leading(&1), key <> "="))

        if present? do
          Enum.map(acc, fn l ->
            if String.starts_with?(String.trim_leading(l), key <> "="), do: line, else: l
          end)
        else
          acc ++ [line]
        end
      end)

    File.write!(path, Enum.join(updated, "\n"))
    File.chmod(path, 0o600)
  end

  def path do
    config_home = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_home, "laev", "config"])
  end

  def load do
    file = read_file(path())

    for {env_key, app_key} <- @keys do
      # Back-compat: accept the older KALA_* / KINO_* names too (env or
      # config file), so a config written before a rename keeps working.
      names =
        [env_key | for(p <- ["KALA_", "KINO_"], do: String.replace_prefix(env_key, "LAEV_", p))]
        |> Enum.uniq()

      value =
        Enum.find_value(names, &System.get_env/1) || Enum.find_value(names, &file[&1])

      if value not in [nil, ""], do: Application.put_env(:laev_app, app_key, value)
    end

    :ok
  end

  @doc "Preferred audio language for source ranking (LAEV_LANG), default \"en\"."
  def lang, do: Application.get_env(:laev_app, :lang) || "en"

  @doc """
  Subtitle language (LAEV_SUBS): the normalized language code, or `nil` when
  disabled ("off"/"none", any case). Defaults to "en" — deliberately NOT
  LAEV_LANG, which is an *audio* ranking preference (a ja-audio fan usually
  still wants English subs unless they say otherwise).
  """
  def subs_lang do
    case Application.get_env(:laev_app, :subs_lang) do
      nil ->
        "en"

      value ->
        case value |> String.trim() |> String.downcase() do
          off when off in ["off", "none", ""] -> nil
          lang -> lang
        end
    end
  end

  @doc """
  Poster preview style (LAEV_POSTERS): "auto" (sharp pixel graphics via the
  terminal's image protocol — the default), "ascii" (colored ASCII glyphs on
  the terminal's own background), "ascii-bg" (ASCII with painted cell
  backgrounds), or "off" (no poster previews).
  """
  def posters do
    case Application.get_env(:laev_app, :posters) do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> "auto"
    end
  end

  @doc """
  Intro/credits skipping (LAEV_SKIP): "ask" (default — show a Skip button
  when an intro is detected, skip only on Tab), "auto" (skip immediately),
  or "off". Detection: AniSkip timestamps for anime + named chapters.
  """
  def skip do
    case Application.get_env(:laev_app, :skip) do
      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          off when off in ["off", "none", "false"] -> "off"
          "auto" -> "auto"
          _ -> "ask"
        end

      _ ->
        "ask"
    end
  end

  @doc """
  Autoplay the next episode when one ends (LAEV_AUTOPLAY): "off" by default —
  binge-watching is strictly opt-in ("on" here, `--binge`, or the post-play
  menu's autoplay entry).
  """
  def autoplay? do
    case Application.get_env(:laev_app, :autoplay) do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["on", "true", "yes", "1"]

      _ ->
        false
    end
  end

  @doc "Whether finishing an anime episode scrobbles to MyAnimeList (LAEV_MAL_SCROBBLE, default on)."
  def mal_scrobble? do
    case Application.get_env(:laev_app, :mal_scrobble) do
      value when is_binary(value) -> String.downcase(String.trim(value)) not in ["off", "false", "no", "0"]
      _ -> true
    end
  end

  @doc "True when the user explicitly set LAEV_SUBS."
  def subs_explicit?, do: Application.get_env(:laev_app, :subs_lang) != nil

  @doc "Which keys are configured (by env-var name), for `laev config`."
  def status do
    for {env_key, app_key} <- @keys, into: %{} do
      {env_key, Application.get_env(:laev_app, app_key) not in [nil, ""]}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            [key, value] <- [String.split(line, "=", parts: 2)],
            into: %{} do
          {String.trim(key), String.trim(value)}
        end

      {:error, _} ->
        %{}
    end
  end
end
