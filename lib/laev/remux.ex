defmodule Laev.Remux do
  @moduledoc """
  Local, on-the-fly HLS remuxer. Given a (range-seekable) source URL, ffmpeg
  stream-copies it into HLS segments on local disk — near-instant and lossless
  for h264/aac, hardware-encoding only when the codec isn't browser-playable.

  Because segments are written faster than realtime and served from disk, the
  browser can seek anywhere the moment that part is segmented (seconds), which
  fixes the slow-seek problem of remote on-demand transcoders.

  This is the public facade; `Laev.Remux.Worker` runs one ffmpeg per id.
  """

  alias Laev.Remux.Worker

  @registry Laev.Remux.Registry
  @supervisor Laev.Remux.Supervisor

  # Remuxed segments are kept on disk this long so a page reload (or replaying
  # the same title) reuses them instead of re-running ffmpeg from the start.
  @cache_ttl_s 24 * 60 * 60

  @doc """
  The conversions running right now.
  """
  def running do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  @doc """
  Say that a conversion is still being watched, so the reaper leaves it alone.

  Whatever serves the segments calls this as it serves them; ten minutes of
  nobody asking is taken for nobody watching.
  """
  def touch(id) when is_binary(id) do
    Laev.Remux.Reaper.touch(id)
    # Both kinds keep their own clock: laev's reaper for the segmented path,
    # `direct`'s own idle stop for the copied one.
    if direct?(), do: apply(Direct, :touch, [id])
    touch_cache(id)
    :ok
  rescue
    _ -> :ok
  end

  def touch(_id), do: :ok

  @doc "Whether ffmpeg is available to remux at all."
  def available?, do: System.find_executable("ffmpeg") != nil

  @doc """
  Start remuxing `url` into HLS. Returns `{:ok, id}`.

  The `id` is derived from `opts[:key]` (a stable per-file identity, e.g.
  filename+size) so the same content always maps to the same folder. If a
  *finished* remux for that id is already on disk (fresh, `#EXT-X-ENDLIST`),
  it's reused instantly with no ffmpeg — so reloading a movie you'd remuxed
  before seeks anywhere immediately instead of re-remuxing from zero. A remux
  already running for that id is likewise reused rather than duplicated.
  """
  def start(url, filename \\ "", opts \\ []) do
    sweep()
    key = Keyword.get(opts, :key) || filename || url
    id = cache_id(key)
    share_directory()

    cond do
      # Already remuxing/serving this exact content — don't start a second ffmpeg.
      running?(id) and File.dir?(dir(id)) ->
        {:ok, id}

      # Registered, but what it was writing is gone: a cache sweep, an `rm`, a
      # full disk. Reusing it would wait on a playlist nothing is writing, so
      # the worker goes and this falls through to a fresh remux below.
      running?(id) ->
        stop(id)
        File.rm_rf(dir(id))
        start(url, filename, opts)

      # A finished, fresh remux is cached on disk. Reuse it (no ffmpeg at all).
      complete?(id) ->
        touch_cache(id)
        {:ok, id}

      # The browser already decodes this video, so there is nothing to encode:
      # copy it as it is. See `direct/3`.
      match?({:ok, _id, _part}, direct(url, id, opts)) ->
        {:ok, id}

      true ->
        # No usable cache: clear any stale/partial dir and remux fresh.
        File.rm_rf(dir(id))
        spec = {Worker, id: id, url: url, filename: filename, dir: dir(id)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _pid} -> {:ok, id}
          {:error, {:already_started, _pid}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Which kind of conversion is on disk under `id`:

    * `:direct` — the video copied as it is, into a fragmented MP4 served as
      byte ranges. Its playlists are `Direct.playlist/3` and
      `Direct.media_playlist/3`, not `entry_playlist/1`.
    * `:hls` — laev's own segmented remux, possibly re-encoded.
    * `:none` — nothing here.

  A host serving the files has to ask, because the two kinds are laid out
  differently in the same directory.
  """
  def kind(id) do
    cond do
      direct?() and apply(Direct, :direct?, [id]) -> :direct
      File.exists?(media_playlist_path(id)) or running?(id) -> :hls
      true -> :none
    end
  end

  # Copy rather than encode, when the client says it decodes the codec.
  #
  # Re-encoding HEVC or AV1 with libx264 takes five to seven cores and a 4K
  # file never keeps up; the `direct` package copies the video into one
  # fragmented MP4 that plays while it is written, and it is the only way HEVC
  # reaches Safari over HLS. It decides for itself — `:skip` when the video is
  # not one these caps decode — so laev offers it the job and falls through to
  # the segmented path on anything but a yes.
  #
  # Only when a caller passes `caps:` (what the player decodes,
  # `Direct.Caps.from_params/1`): the terminal plays through mpv, which decodes
  # everything itself and wants none of this, which is also why the dependency
  # is optional.
  defp direct(url, id, opts) do
    caps = Keyword.get(opts, :caps)

    if direct?() and is_map(caps) and caps != %{} do
      apply(Direct, :start, [url, [id: id, caps: caps, from: Keyword.get(opts, :from, 0)]])
    else
      :skip
    end
  rescue
    _ -> :skip
  end

  defp direct?, do: Code.ensure_loaded?(Direct) and function_exported?(Direct, :start, 2)

  @doc """
  Point `direct` at laev's directory layout, so both kinds of conversion live
  under the same id in the same place and one id is an address a host can serve
  either from.

  Called at boot, and again before starting a conversion for anything that runs
  laev as a library without its supervision tree. Set here rather than asked of
  config, because an application depending on laev has its own config and
  should not have to know this.
  """
  def share_directory do
    if direct?() and Application.get_env(:direct, :dir) == nil do
      Application.put_env(:direct, :dir, {__MODULE__, :dir})
    end

    :ok
  end

  # A deterministic 16-hex id for a content key, valid for `valid_id?/1`.
  defp cache_id(key) do
    :sha256 |> :crypto.hash(to_string(key)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp running?(id), do: Registry.lookup(@registry, id) != []

  @doc """
  Whether this id has a finished remux on disk — a media playlist carrying
  `#EXT-X-ENDLIST`, written recently enough to still be a cache. `start/3`
  reuses one of these with no ffmpeg at all.
  """
  def complete?(id) do
    path = media_playlist_path(id)

    case File.read(path) do
      {:ok, content} -> content =~ "#EXT-X-ENDLIST" and fresh?(path)
      _ -> false
    end
  end

  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> System.os_time(:second) - m < @cache_ttl_s
      _ -> false
    end
  end

  # Bump the dir's mtime so reusing a cache keeps it alive another TTL.
  defp touch_cache(id) do
    now = System.os_time(:second)
    _ = File.touch(media_playlist_path(id), now)
    _ = File.touch(Path.join(dir(id), entry_playlist(id)), now)
    _ = File.touch(dir(id), now)
    :ok
  end

  @doc """
  Delete cached remux dirs older than the TTL (best-effort). Runs on each
  `start/3` so old segments don't accumulate. Never touches a running remux.
  """
  def sweep do
    base = Path.join(System.tmp_dir!(), "realdebrid_remux")
    now = System.os_time(:second)

    with {:ok, ids} <- File.ls(base) do
      Enum.each(ids, fn id ->
        d = Path.join(base, id)
        marker = Path.join(d, "index.m3u8")
        stat = File.stat(marker, time: :posix)
        stat = if match?({:ok, _}, stat), do: stat, else: File.stat(d, time: :posix)

        case stat do
          {:ok, %{mtime: m}} -> if now - m > @cache_ttl_s and not running?(id), do: File.rm_rf(d)
          _ -> :ok
        end
      end)
    end

    :ok
  end

  @doc """
  Block until the remux is playable.

    * `:complete` (default) — wait for the finished VOD playlist (`#EXT-X-ENDLIST`).
      hls.js then loads a full VOD and plays from the start. Best for short
      content (an episode remuxes in ~20s); used so it never lands on a live edge.
    * `:fast` — wait for just the first few segments, then start (paired with
      hls.js `startPosition: 0`, which pins playback to the beginning). Good for
      movies, where a full remux would be a multi-minute wait.
  """
  def await_ready(id, mode \\ :complete, timeout \\ 300_000) do
    wait_ready(id, mode, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_ready(id, mode, timeout, started) do
    cond do
      ready?(id, mode) ->
        :ok

      System.monotonic_time(:millisecond) - started > timeout ->
        {:error, :timeout}

      true ->
        Process.sleep(300)
        wait_ready(id, mode, timeout, started)
    end
  end

  defp ready?(id, :complete), do: playlist(id) =~ "#EXT-X-ENDLIST"
  # Ready once there are a few segments to play — or immediately if it's a
  # finished (cached) remux, however short.
  defp ready?(id, :fast) do
    pl = playlist(id)
    pl =~ "#EXT-X-ENDLIST" or length(String.split(pl, ".ts")) >= 4
  end

  @doc """
  The playlist the browser should load: `master.m3u8` for a multi-audio remux
  (switchable audio renditions), else the plain `index.m3u8`.
  """
  def entry_playlist(id) do
    if File.exists?(Path.join(dir(id), "master.m3u8")), do: "master.m3u8", else: "index.m3u8"
  end

  defp playlist(id) do
    case File.read(media_playlist_path(id)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  # The media playlist that actually receives video segments — used for
  # readiness/completeness. Multi-audio splits into per-variant playlists, where
  # the video variant is `s_0.m3u8`; single-audio is just `index.m3u8`.
  defp media_playlist_path(id) do
    d = dir(id)
    if File.exists?(Path.join(d, "master.m3u8")), do: Path.join(d, "s_0.m3u8"), else: Path.join(d, "index.m3u8")
  end

  @doc "Temp directory holding this id's playlist and segments."
  def dir(id), do: Path.join([System.tmp_dir!(), "realdebrid_remux", id])

  @doc "Ids are 16 lowercase hex chars — validate before touching the filesystem."
  def valid_id?(id) when is_binary(id), do: id =~ ~r/^[a-f0-9]{16}$/
  def valid_id?(_), do: false

  @doc "Embedded subtitle tracks discovered in the remuxed file (list of %{lang, file})."
  def subtitles(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.call(pid, :subtitles)
      # No worker (a reused cache): recover the track list from the manifest the
      # worker wrote, so embedded subs still show up after a reload.
      [] -> read_subs_manifest(id)
    end
  end

  @doc "Path of the sub-track manifest the worker persists alongside the segments."
  def subs_manifest(id), do: Path.join(dir(id), "subs.json")

  defp read_subs_manifest(id) do
    with {:ok, body} <- File.read(subs_manifest(id)),
         {:ok, list} when is_list(list) <- Jason.decode(body) do
      Enum.map(list, fn m -> %{index: m["index"] || 0, lang: m["lang"] || "", file: m["file"]} end)
    else
      _ -> []
    end
  end

  @doc "Stop a remux worker (kills ffmpeg, removes its temp dir). Safe on nil."
  def stop(nil), do: :ok

  def stop(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end
end
