defmodule Laev.SubtitleFetch do
  @moduledoc """
  Fetch an external subtitle file for a title/episode and save it locally so
  a desktop player can load it (`mpv --sub-file=<path>`).

  Anime goes to Jimaku (release-timed JP/EN files, no download quota), with
  OpenSubtitles as the English fallback; everything else goes to
  OpenSubtitles. Files are kept in their native format — mpv renders .srt and
  .ass (with styling) directly, so no VTT conversion is needed.

  Files are cached on disk under deterministic names, so replaying a title
  never re-downloads (OpenSubtitles has a small daily download quota); stale
  cache entries are pruned. Fetching is best-effort by contract: any
  exception is caught and returned as an error — a subtitle problem must
  never break playback.
  """

  alias Laev.{Jimaku, OpenSubtitles}

  @cache_max_age_s 30 * 24 * 3600

  @doc """
  Fetch the best subtitle for the play context in `lang` (ISO 639-1).

  `ctx` needs `:type`, `:title`, `:tmdb_id`; optional `:season`, `:episode`,
  `:anime`, `:search_title` (the release-name title, e.g. romaji for anime).

  Returns `{:ok, path, label}`, `{:error, :no_provider}` when nothing is
  configured for this content, or `{:error, reason}`.
  """
  def fetch(ctx, lang) do
    do_fetch(ctx, lang)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_fetch(ctx, lang) do
    anime? = Map.get(ctx, :anime, false)
    query = Map.get(ctx, :search_title) || ctx.title

    cond do
      anime? and lang in ["ja", "en"] and Jimaku.configured?() ->
        case jimaku(query, ctx[:episode], lang) do
          {:ok, _, _} = ok ->
            ok

          {:error, reason} when lang == "en" ->
            # Fall back to OpenSubtitles, but keep Jimaku's reason if that
            # fails too — ":no_provider" would hide what actually happened.
            with {:error, _} <- opensubtitles(ctx, query, lang), do: {:error, reason}

          error ->
            error
        end

      OpenSubtitles.configured?() ->
        opensubtitles(ctx, query, lang)

      true ->
        {:error, :no_provider}
    end
  end

  defp jimaku(query, episode, lang) do
    jlang = if lang == "ja", do: :japanese, else: :english

    with {:ok, %{name: name, url: url} = file} <- Jimaku.subtitle_file(query, episode, jlang) do
      path = cache_path("jimaku-#{slug(name)}", name)
      label = "Jimaku · #{name}"

      cond do
        File.exists?(path) ->
          {:ok, path, label}

        # The English picker already downloaded the body to verify language.
        is_binary(file[:body]) ->
          {:ok, save(path, file.body), label}

        true ->
          case Req.get(url,
                 receive_timeout: 20_000,
                 decode_body: false,
                 retry: :transient,
                 max_retries: 1
               ) do
            {:ok, %{status: 200, body: body}} when is_binary(body) ->
              {:ok, save(path, body), label}

            other ->
              {:error, {:jimaku_download, other}}
          end
      end
    end
  end

  defp opensubtitles(ctx, query, lang) do
    cond do
      not OpenSubtitles.configured?() ->
        {:error, :no_provider}

      not OpenSubtitles.can_download?() ->
        {:error, :opensubtitles_needs_login}

      true ->
        # For anime, :season is nil on purpose (absolute numbering) — omit it
        # rather than inventing season 1; search/1 drops nil params.
        opts =
          case ctx[:type] do
            "tv" ->
              [
                languages: lang,
                query: query,
                season_number: ctx[:season],
                episode_number: ctx[:episode]
              ]

            _ ->
              [languages: lang, query: query, tmdb_id: ctx[:tmdb_id]]
          end

        with {:ok, [best | _]} <- OpenSubtitles.search(opts) do
          path = cache_path("os-#{best.file_id}", "#{best.release}.srt")
          label = "OpenSubtitles · #{best.release}"

          if File.exists?(path) do
            {:ok, path, label}
          else
            with {:ok, srt} <- OpenSubtitles.download_srt(best.file_id) do
              {:ok, save(path, srt), label}
            end
          end
        else
          {:ok, []} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ── on-disk cache ─────────────────────────────────────────────────

  # Deterministic path in the cache dir, keeping the original extension so
  # mpv picks the subtitle format from it.
  defp cache_path(base, original_name) do
    ext =
      case Path.extname(String.downcase(original_name)) do
        e when e != "" ->
          if e in Laev.Subtitles.extensions(), do: e, else: ".srt"

        _ ->
          ".srt"
      end

    dir = Path.join(System.tmp_dir!(), "laev-subs")
    File.mkdir_p!(dir)
    prune(dir)
    Path.join(dir, base <> ext)
  end

  defp save(path, content) do
    File.write!(path, content)
    path
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 80)
  end

  defp prune(dir) do
    cutoff = System.os_time(:second) - @cache_max_age_s

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir, name),
            {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
            mtime < cutoff do
          File.rm(path)
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  The subtitles on offer for this episode, rather than the one laev would pick.

  `fetch/2` answers with a single best file, which is the right answer for a
  player that just needs subtitles on — and no use to anything that wants to
  show a menu, because the pick is often wrong in a way only the viewer can
  see: a streaming cut timed half a minute off the rip, or a release in the
  wrong dialect. This lists what there is.

  `{:ok, [%{provider:, id:, label:, release:, downloads:}]}`, or
  `{:error, :no_provider}` when nothing is configured. Searching OpenSubtitles
  needs only the API key — the login is for downloading — so the list is
  available even when `fetch/2` would say it needs one.
  """
  def candidates(ctx, lang, limit \\ 25) do
    query = ctx[:search_title] || ctx[:title]

    cond do
      OpenSubtitles.configured?() -> os_candidates(ctx, query, lang, limit)
      Laev.Jimaku.configured?() and lang in ["ja", "jpn", "japanese"] -> jimaku_candidates(ctx, query)
      true -> {:error, :no_provider}
    end
  end

  defp os_candidates(ctx, query, lang, limit) do
    opts =
      case ctx[:type] do
        "tv" -> [languages: lang, query: query, season_number: ctx[:season], episode_number: ctx[:episode]]
        _ -> [languages: lang, query: query, tmdb_id: ctx[:tmdb_id]]
      end

    case OpenSubtitles.search(opts) do
      {:ok, subs} ->
        {:ok,
         subs
         |> Enum.uniq_by(& &1.file_id)
         |> Enum.take(limit)
         |> Enum.map(
           &%{
             provider: :opensubtitles,
             id: &1.file_id,
             label: &1.release,
             release: &1.release,
             downloads: &1[:downloads]
           }
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp jimaku_candidates(ctx, query) do
    case Laev.Jimaku.candidates(query, ctx[:episode], ctx[:release_name]) do
      {:ok, files} ->
        {:ok,
         Enum.map(files, &%{provider: :jimaku, id: &1.url, label: &1.name, release: &1.name, downloads: nil})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  One chosen subtitle, as a file on disk: `{:ok, path}` or `{:error, reason}`.

  Kept for good once fetched, keyed by the provider's own file id. A free
  OpenSubtitles account has a small daily download quota — the service answers
  406 when it is used up — so paying for the same file twice is a real cost,
  not a tidiness matter. The cache is read before the service is asked at all.
  """
  def download(%{provider: :opensubtitles, id: id} = candidate) do
    path = cache_path("os-#{id}", "#{candidate[:release] || id}.srt")

    if File.exists?(path) do
      {:ok, path}
    else
      case OpenSubtitles.download_srt(id) do
        {:ok, body} ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          {:ok, path}

        {:error, {:opensubtitles_download, 406, _body}} ->
          {:error, :quota_used_up}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def download(%{provider: :jimaku, id: url, label: name}) do
    path = cache_path("jimaku-#{:erlang.phash2(url)}", name || "subs.srt")

    if File.exists?(path) do
      {:ok, path}
    else
      case Req.get(url, retry: :transient, max_retries: 1, receive_timeout: 20_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          {:ok, path}

        _ ->
          {:error, :download_failed}
      end
    end
  end

  def download(_candidate), do: {:error, :unknown_provider}
end
