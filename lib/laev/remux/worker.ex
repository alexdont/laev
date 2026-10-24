defmodule Laev.Remux.Worker do
  @moduledoc """
  Runs one ffmpeg process that remuxes a source URL into an HLS playlist +
  segments on disk. Owns the OS process and temp dir; killing the worker kills
  ffmpeg and cleans up.
  """

  use GenServer, restart: :temporary
  require Logger

  # Hard lifetime cap so orphaned remuxes can't accumulate.
  @ttl_ms 2 * 60 * 60 * 1000

  # Nothing is re-encoded above this height. A browser on a laptop is not
  # watching 4K, and the encode is what makes it unwatchable.
  @max_height 1080

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Laev.Remux.Registry, id}})
  end

  @impl true
  def init(opts) do
    state = %{
      id: opts[:id],
      url: opts[:url],
      dir: opts[:dir],
      port: nil,
      os_pid: nil,
      last_error: nil,
      subs: []
    }

    # Trap exits so terminate/2 runs on supervisor shutdown (kills ffmpeg,
    # removes the temp dir).
    Process.flag(:trap_exit, true)
    File.mkdir_p!(state.dir)
    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state) do
    subs = probe_subs(state.url)
    # Persist the track list so a reused cache (no worker) can still expose subs.
    write_subs_manifest(state.dir, subs)
    args = ffmpeg_args(state.url, state.dir, subs)
    ffmpeg = System.find_executable("ffmpeg")
    port = Port.open({:spawn_executable, ffmpeg}, [:binary, :exit_status, :stderr_to_stdout, args: args])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Process.send_after(self(), :ttl, @ttl_ms)
    {:noreply, %{state | port: port, os_pid: os_pid, subs: subs}}
  end

  @impl true
  def handle_call(:subtitles, _from, state), do: {:reply, state.subs, state}

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0, do: Logger.warning("remux #{state.id} ffmpeg exited #{status}: #{state.last_error}")
    # Keep the worker alive to serve the already-written segments; TTL/stop cleans up.
    {:noreply, %{state | port: nil}}
  end

  # ffmpeg logs to stderr — keep the last line for diagnostics.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | last_error: data |> String.trim() |> last_line()}}
  end

  def handle_info(:ttl, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Kill ffmpeg but KEEP the segments on disk — they're a cache reused on the
    # next play/reload (Remux.sweep/0 evicts dirs older than the TTL).
    if state.os_pid, do: System.cmd("kill", ["-9", to_string(state.os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp write_subs_manifest(dir, subs) do
    File.write(Path.join(dir, "subs.json"), Jason.encode!(subs))
  end

  # ── ffmpeg command ────────────────────────────────────────────────

  defp ffmpeg_args(url, dir, subs) do
    {video_codec, audio_codec} = probe(url)
    audios = probe_audios(url)

    # Copy h264 video (lossless, fast); otherwise encode to h264 so the browser
    # can play it, on whatever this machine can encode with.
    video =
      if video_codec == "h264",
        do: ["-c:v", "copy"],
        else: encode_args(h264_encoder())

    hls =
      if length(audios) > 1,
        do: multi_audio_hls(dir, audios, video),
        else: single_audio_hls(dir, video, audio_codec)

    # Extract each embedded subtitle track to WebVTT in the same read pass.
    sub_outputs =
      Enum.flat_map(subs, fn s ->
        ["-map", "0:#{s.index}", "-c:s", "webvtt", "-f", "webvtt", Path.join(dir, "#{s.file}.vtt")]
      end)

    ["-nostdin", "-loglevel", "error", "-i", url] ++ hls ++ sub_outputs
  end

  # Re-encoding, at a speed that keeps up with watching.
  #
  # This was `-b:v 6M` and nothing else: no speed preset, so libx264 ran at its
  # default, and no scaling, so a 4K source was encoded at 4K. A French Lupin
  # H.265 2160p release never reached real time and took every core trying;
  # four of them put the host at a load average near 150. A film nobody can
  # watch is not worth any amount of CPU.
  #
  # So: the fastest preset each encoder offers, and the output capped at 1080p
  # (`-2` keeps the aspect and an even width, which h264 requires). 10-bit and
  # HDR sources are brought to 8-bit 4:2:0, which is what a browser can read
  # anyway.
  defp encode_args(encoder) do
    ["-c:v", encoder] ++
      preset_for(encoder) ++
      [
        "-b:v",
        "6M",
        "-vf",
        "scale=-2:'min(#{@max_height},ih)'",
        "-pix_fmt",
        "yuv420p"
      ]
  end

  # Every encoder spells "fast" differently, and an unknown one gets nothing
  # rather than a flag it would refuse.
  defp preset_for("libx264"), do: ["-preset", "veryfast"]
  defp preset_for("h264_nvenc"), do: ["-preset", "p1", "-tune", "ll"]
  defp preset_for("h264_qsv"), do: ["-preset", "veryfast"]
  defp preset_for("h264_vaapi"), do: ["-compression_level", "7"]
  defp preset_for("h264_amf"), do: ["-quality", "speed"]
  defp preset_for("h264_videotoolbox"), do: ["-realtime", "1"]
  defp preset_for(_encoder), do: []

  # Which h264 encoder this machine has, best first.
  #
  # This used to be videotoolbox and nothing else, which exists only on macOS —
  # so on a Linux server every release that was not already h264 failed the
  # moment ffmpeg started, and the page waited for segments that were never
  # going to come. Asked once per run and remembered.
  @encoders ["h264_nvenc", "h264_qsv", "h264_vaapi", "h264_amf", "h264_videotoolbox", "libx264"]

  defp h264_encoder do
    case :persistent_term.get({__MODULE__, :encoder}, nil) do
      nil ->
        found = detect_encoder()
        :persistent_term.put({__MODULE__, :encoder}, found)
        found

      cached ->
        cached
    end
  end

  defp detect_encoder do
    # Tried rather than listed. ffmpeg will happily report an encoder it cannot
    # actually run — h264_nvenc is in the list on a machine with no NVIDIA
    # driver, and only says "Cannot load libcuda.so.1" once a film is waiting
    # on it. Encoding two frames of a test pattern settles it in about a
    # second, once per run.
    Enum.find(@encoders, "libx264", &encodes?/1)
  end

  defp encodes?(name) do
    args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=128x128:rate=5:duration=0.4",
      "-c:v",
      name,
      "-f",
      "null",
      "-"
    ]

    match?({_out, 0}, System.cmd("ffmpeg", args, stderr_to_stdout: true))
  rescue
    _ -> false
  end

  # One audio track: a plain HLS media playlist (index.m3u8). Copy AAC, else AAC.
  defp single_audio_hls(dir, video, audio_codec) do
    # Downmixed to stereo when it has to be re-encoded at all: HLS carries AAC
    # in ADTS, which cannot describe more than seven channels, and a TrueHD
    # 7.1 track is eight — ffmpeg refuses the whole file over it, which is a
    # silent failure on exactly the releases most worth watching. A browser
    # plays stereo regardless.
    audio = if audio_codec == "aac", do: ["-c:a", "copy"], else: ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]

    ["-map", "0:v:0", "-map", "0:a:0", "-sn"] ++
      video ++
      audio ++
      hls_common() ++
      ["-hls_segment_filename", Path.join(dir, "seg%05d.ts"), Path.join(dir, "index.m3u8")]
  end

  # Dual/multi audio (common for anime: JP + EN dub): emit a master playlist with
  # each audio as a switchable HLS rendition so hls.js can flip tracks live. All
  # audio is transcoded to AAC so every track is browser-playable. Segments and
  # variant playlists are named s_<variant>… ; the master is master.m3u8.
  defp multi_audio_hls(dir, audios, video) do
    maps =
      ["-map", "0:v:0"] ++ Enum.flat_map(0..(length(audios) - 1), fn i -> ["-map", "0:a:#{i}"] end)

    maps ++
      ["-sn"] ++
      video ++
      ["-c:a", "aac", "-b:a", "192k", "-ac", "2"] ++
      hls_common() ++
      [
        "-master_pl_name", "master.m3u8",
        "-var_stream_map", var_stream_map(audios),
        "-hls_segment_filename", Path.join(dir, "s_%v_%05d.ts"),
        Path.join(dir, "s_%v.m3u8")
      ]
  end

  defp hls_common do
    [
      "-f", "hls",
      "-hls_time", "4",
      # "event" writes the playlist incrementally (append-only) so playback can
      # start within seconds, and gains ENDLIST (full VOD seek) on finish.
      "-hls_playlist_type", "event",
      "-hls_flags", "independent_segments",
      "-hls_list_size", "0"
    ]
  end

  # "v:0,agroup:aud a:0,agroup:aud,name:Japanese,language:jpn,default:yes a:1,…"
  defp var_stream_map(audios) do
    audio_parts =
      audios
      |> Enum.with_index()
      |> Enum.map(fn {a, i} ->
        lang = if a.lang != "", do: ",language:#{a.lang}", else: ""
        default = if i == 0, do: ",default:yes", else: ""
        "a:#{i},agroup:aud,name:#{audio_name(a.lang, i)}#{lang}#{default}"
      end)

    Enum.join(["v:0,agroup:aud" | audio_parts], " ")
  end

  # HLS rendition names must be single tokens (no spaces/commas) — map language
  # codes to friendly one-word labels; fall back to Track1/Track2.
  defp audio_name(lang, i) do
    case String.downcase(lang) do
      l when l in ~w(jpn ja jp) -> "Japanese"
      l when l in ~w(eng en) -> "English"
      l when l in ~w(fre fra fr) -> "French"
      l when l in ~w(spa es) -> "Spanish"
      l when l in ~w(ger deu de) -> "German"
      l when l in ~w(ita it) -> "Italian"
      l when l in ~w(por pt) -> "Portuguese"
      l when l in ~w(chi zho zh) -> "Chinese"
      l when l in ~w(kor ko) -> "Korean"
      "" -> "Track#{i + 1}"
      other -> String.capitalize(other)
    end
  end

  # List audio streams in order, with their language tag (for naming/switching).
  # Include `index` so a track *without* a language tag still yields a (non-empty)
  # line — otherwise it'd be dropped and multi-audio miscounted as single.
  defp probe_audios(url) do
    args = [
      "-v", "error", "-select_streams", "a",
      "-show_entries", "stream=index:stream_tags=language",
      "-of", "csv=p=0", url
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          parts = String.split(line, ",")
          %{lang: parts |> Enum.at(1, "") |> to_string() |> String.trim()}
        end)

      _ ->
        []
    end
  end

  defp probe(url), do: {ffprobe(url, "v:0"), ffprobe(url, "a:0")}

  defp ffprobe(url, stream) do
    args = ["-v", "error", "-select_streams", stream, "-show_entries", "stream=codec_name", "-of", "csv=p=0", url]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> last_line()
      _ -> ""
    end
  end

  # List embedded subtitle streams as %{index, lang, file}. `file` is the served
  # basename (sub0, sub1, …). Skips image-based subs (PGS/VobSub) which can't be VTT.
  defp probe_subs(url) do
    args = [
      "-v", "error", "-select_streams", "s",
      "-show_entries", "stream=index,codec_name:stream_tags=language",
      "-of", "csv=p=0", url
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, ","))
        |> Enum.reject(fn parts -> Enum.at(parts, 1) in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"] end)
        |> Enum.with_index()
        |> Enum.map(fn {[index | rest], n} ->
          %{index: String.to_integer(index), lang: Enum.at(rest, 1, "") || "", file: "sub#{n}"}
        end)

      _ ->
        []
    end
  end

  defp last_line(""), do: ""
  defp last_line(text), do: text |> String.split("\n") |> List.last() |> String.trim()
end
