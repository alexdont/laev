defmodule Laev.Position do
  @moduledoc """
  Exact playback-position memory, crash-safe.

  A tiny Lua script (mpv has a built-in Lua engine — no dependencies) writes
  the current second to a file every 5 seconds while mpv plays, so the
  position survives player crashes and power loss. The file is keyed by
  title + episode — NOT by stream URL — so switching to a different source
  of the same episode resumes from the same spot.

  Positions under 30s aren't kept (no point), and finishing a title (>95%)
  clears it so a rewatch starts from the beginning.
  """

  @min_resume 30

  @script """
  -- laev position tracker: persists time-pos so playback survives crashes,
  -- and remembers the selected subtitle/audio tracks per source.
  -- Written by laev on every launch; do not edit.
  local options = require "mp.options"
  local opts = { file = "", tracks = "", played = "" }
  options.read_options(opts, "laev")

  -- Time actually watched, as opposed to time the playhead covered. The
  -- timer fires every 5s, so a sample that moved the playhead about 5s is
  -- playback and a sample that moved it minutes is a seek. Speed is folded
  -- in (at 2x a real 5s tick advances 10s), and rewinds count as neither —
  -- they are re-watching, already paid for. Totals accumulate across
  -- sessions, so resuming an episode tomorrow adds to today.
  local watched = 0
  local skipped = 0
  local last_pos = nil

  local function write_played()
    if opts.played == "" then return end
    local f = io.open(opts.played, "w")
    if f then
      f:write(string.format("%d %d", math.floor(watched), math.floor(skipped)))
      f:close()
    end
  end

  local function load_played()
    watched, skipped = 0, 0
    last_pos = nil
    if opts.played == "" then return end
    local f = io.open(opts.played, "r")
    if f then
      local w, s = f:read("*a"):match("(%d+)%s+(%d+)")
      f:close()
      if w then watched = tonumber(w) skipped = tonumber(s) end
    end
  end

  local function accumulate()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    if last_pos then
      local delta = pos - last_pos
      local speed = mp.get_property_number("speed") or 1
      -- what one second of real playback can advance the playhead by
      local budget = speed * 1.5 + 0.5
      if delta > 0 and delta <= budget then
        watched = watched + delta
      elseif delta > budget then
        skipped = skipped + delta
      end
    end
    last_pos = pos
  end

  -- Per-series track memory: when the user switches audio/subtitle track,
  -- remember the LANGUAGE (not the track id — ids differ between releases,
  -- languages carry across every episode/season). Saved as "ALANG SLANG"
  -- (slang "off" = subtitles disabled). laev applies it to the whole series
  -- via --alang/--slang, overriding the global default just for this show.
  -- A 2s settle window after load ignores mpv's own initial auto-selection
  -- so only a real manual change is recorded.
  local ready = false
  local settled = false

  mp.register_event("file-loaded", function()
    ready = true
    settled = false
    load_played()
    mp.add_timeout(2, function() settled = true end)
  end)
  mp.register_event("end-file", function() ready = false end)

  local function save_tracks()
    if opts.tracks == "" or not ready or not settled then return end
    local alang = mp.get_property("current-tracks/audio/lang")
    local slang = mp.get_property("current-tracks/sub/lang")
    -- No selected sub track = subtitles off (the user disabled them).
    if slang == nil then slang = "off" end
    -- Untagged audio has no language to remember — skip rather than store junk.
    if alang == nil or alang == "" then return end
    local f = io.open(opts.tracks, "w")
    if f then
      f:write(alang .. " " .. slang)
      f:close()
    end
  end

  mp.observe_property("sid", "native", save_tracks)
  mp.observe_property("aid", "native", save_tracks)

  local function write(n)
    if opts.file == "" then return end
    local f = io.open(opts.file, "w")
    if f then
      f:write(string.format("%d", n))
      f:close()
    end
  end

  -- "done" is the watched marker (Up Next / grayed ✓ in pickers); it parses
  -- as no-resume, so a rewatch starts over. An episode counts as watched at
  -- 90% — you stop before the credits/ED. Guard against live-ish streams
  -- (HLS transcode) where duration just tracks position and 90% is always
  -- true: only trust the percentage once we've actually seen the playhead
  -- in the first half (real duration), which never happens when dur≈pos.
  local saw_early = false

  local function mark_done()
    if opts.file == "" then return end
    local f = io.open(opts.file, "w")
    if f then f:write("done") f:close() end
  end

  local function save()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    write_played()
    local dur = mp.get_property_number("duration")

    if dur and dur > 0 and pos < dur * 0.5 then saw_early = true end

    if saw_early and dur and dur > 0 and pos >= dur * 0.85 then
      mark_done()
      return
    end

    if pos < 30 then pos = 0 end
    write(math.floor(pos))
  end

  mp.add_periodic_timer(1, accumulate)
  mp.add_periodic_timer(5, save)
  mp.register_event("shutdown", save)
  mp.register_event("end-file", function(e)
    if e and e.reason == "eof" then mark_done() end
  end)
  """

  @doc """
  mpv arguments for position tracking + resume, as `{args, resume_at}`
  where `resume_at` is a human-readable time when resuming, else nil.
  Best-effort: any failure returns `{[], nil}` — never breaks playback.
  """
  def mpv_args(ctx, _filename \\ nil) do
    case key(ctx) do
      nil ->
        {[], nil}

      key ->
        file = position_file(key)
        # Track memory is per-SERIES (not per-episode/file): a language
        # choice on one episode applies to every episode and season.
        tracks = tracks_file(series_key(ctx))
        played = played_file(key)

        # -append: a plain --script-opts= would replace the whole list and
        # wipe other scripts' opts (e.g. the skip windows).
        args =
          [
            "--script=#{script_path()}",
            "--script-opts-append=laev-file=#{file}",
            "--script-opts-append=laev-tracks=#{tracks}",
            "--script-opts-append=laev-played=#{played}"
          ] ++ track_args(tracks)

        case read(file) do
          nil -> {args, nil}
          secs -> {args ++ ["--start=#{secs}"], format(secs)}
        end
    end
  rescue
    _ -> {[], nil}
  end

  # Apply the series' remembered languages as --alang/--slang, overriding the
  # global default just for this show. Stored as "ALANG SLANG" (slang "off" =
  # subtitles disabled). Languages carry across releases; track ids don't.
  defp track_args(tracks_path) do
    with {:ok, contents} <- File.read(tracks_path),
         [alang, slang] <- contents |> String.trim() |> String.split(" ", parts: 2) do
      audio = if alang in ["", "no", "off"], do: [], else: ["--aid=auto", "--alang=#{Laev.Player.lang_codes(alang)}"]

      subs =
        case slang do
          s when s in ["off", "no", ""] -> ["--sid=no"]
          s -> ["--sid=auto", "--slang=#{Laev.Player.lang_codes(s)}", "--sub-auto=fuzzy"]
        end

      audio ++ subs
    else
      _ -> []
    end
  end

  # Series-level key for track memory: type + tmdb id, no season/episode.
  defp series_key(%{type: type, tmdb_id: id}) when type in ["movie", "tv"] and not is_nil(id),
    do: "#{type}-#{id}"

  defp series_key(_), do: "unknown"

  defp tracks_file(key) do
    dir = Path.join(data_dir(), "tracks")
    File.mkdir_p!(dir)
    Path.join(dir, key)
  end

  @doc "True when this title/episode was watched to the end (mpv hit eof)."
  def finished?(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, body} <- File.read(position_file(key)) do
      # "done" is written by playback reaching the end; "seen" by hand. Both
      # mean watched here — the difference only matters to the stats, which
      # must not bill you for hours it never saw you spend.
      String.trim(body) in ["done", "seen"]
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  True when this episode counts as watched: marked "done", OR — when the
  episode runtime (seconds) is known — the saved position is past 85% of it.
  The runtime check retroactively catches episodes watched before the 85%
  marker existed (their position is a plain number, not "done").
  """
  def watched?(ctx, runtime_s \\ nil) do
    finished?(ctx) or
      (is_number(runtime_s) and runtime_s > 0 and
         case saved_seconds(ctx) do
           n when is_integer(n) -> n >= runtime_s * 0.85
           _ -> false
         end)
  rescue
    _ -> false
  end

  @doc """
  Mark a title or episode watched by hand, or clear the mark.

  Writes "seen" rather than the "done" playback leaves behind: it says you
  have watched this, not that laev watched you watch it, so the stats can
  count it as watched without adding a runtime it never measured.
  """
  def set_watched(ctx, true) do
    with key when is_binary(key) <- key(ctx), do: File.write(position_file(key), "seen")
    :ok
  rescue
    _ -> :ok
  end

  def set_watched(ctx, false) do
    with key when is_binary(key) <- key(ctx), do: File.rm(position_file(key))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Erase every saved position and play record for a title — the title's own
  file and each of its episodes. Returns how many files went.

  This is the destructive half of removing something from your history: those
  files are the watched marks and the only record of time spent, so a show
  forgotten here leaves the stats too.
  """
  def forget(type, tmdb_id) do
    prefix = "#{type}-#{tmdb_id}"

    Enum.reduce(["positions", "played"], 0, fn sub, count ->
      dir = Path.join(data_dir(), sub)

      case File.ls(dir) do
        {:ok, names} ->
          names
          # `-` guarded, or forgetting movie-15 would take movie-150 with it.
          |> Enum.filter(&(&1 == prefix or String.starts_with?(&1, prefix <> "-")))
          |> Enum.reduce(count, fn name, count ->
            case File.rm(Path.join(dir, name)) do
              :ok -> count + 1
              _ -> count
            end
          end)

        _ ->
          count
      end
    end)
  end

  defp saved_seconds(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, body} <- File.read(position_file(key)),
         {n, _} <- Integer.parse(String.trim(body)) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  When the position file was last written (posix seconds), or nil. The Lua
  tracker saves every 5s while mpv runs — a stale mtime means mpv is gone.
  """
  def last_saved_at(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, %{mtime: mtime}} <- File.stat(position_file(key), time: :posix) do
      mtime
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Human-readable stored position for a play context, or nil."
  def resume_at(ctx) do
    with key when is_binary(key) <- key(ctx),
         secs when is_integer(secs) <- read(position_file(key)) do
      format(secs)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp key(%{type: type, tmdb_id: id} = ctx) when type in ["movie", "tv"] and not is_nil(id) do
    base = "#{type}-#{id}"

    cond do
      ctx[:season] && ctx[:episode] -> "#{base}-s#{ctx[:season]}e#{ctx[:episode]}"
      ctx[:episode] -> "#{base}-e#{ctx[:episode]}"
      true -> base
    end
  end

  defp key(_ctx), do: nil

  defp read(file) do
    with {:ok, body} <- File.read(file),
         {secs, _} when secs >= @min_resume <- Integer.parse(String.trim(body)) do
      secs
    else
      _ -> nil
    end
  end

  defp format(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # Rewritten on every launch so it always matches this app version.
  @doc false
  # Exposed so the test suite can run the real script under a Lua interpreter:
  # a script that dies on its first event is invisible to any Elixir test.
  def script_source, do: @script

  defp script_path do
    File.mkdir_p!(data_dir())
    path = Path.join(data_dir(), "position.lua")
    File.write!(path, @script)
    path
  end

  @doc """
  When the play counter was last written (posix seconds), or nil.

  The mpv script rewrites it every 5 seconds while the player is up, so this
  is a heartbeat: recent means mpv is still there. Unlike the position file
  it is never touched by a sync pull, so a sync can't fake one.
  """
  def heartbeat_at(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, %{mtime: mtime}} <- File.stat(played_file(key), time: :posix) do
      mtime
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  How much of this title was actually watched, and how much was skipped past,
  in seconds — `nil` for anything played before laev started measuring. Only
  the mpv script writes it, so it covers real playback and nothing else.
  """
  def played(ctx) do
    with key when is_binary(key) <- key(ctx),
         {:ok, body} <- File.read(played_file(key)),
         [watched, skipped] <- String.split(String.trim(body), " ", parts: 2),
         {watched, _} <- Integer.parse(watched),
         {skipped, _} <- Integer.parse(skipped) do
      %{watched: watched, skipped: skipped}
    else
      _ -> nil
    end
  end

  defp played_file(key) do
    dir = Path.join(data_dir(), "played")
    File.mkdir_p(dir)
    Path.join(dir, key)
  end

  defp position_file(key) do
    dir = Path.join(data_dir(), "positions")
    File.mkdir_p!(dir)
    Path.join(dir, key)
  end

  defp data_dir do
    Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
  end
end
