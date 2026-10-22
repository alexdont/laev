defmodule Laev.VLC do
  @moduledoc """
  Playing through VLC instead of mpv, and knowing where you got to.

  mpv carries a Lua script laev writes on every launch: it saves the position
  every five seconds, counts the seconds actually watched as against seeked
  past, and appends the day's total to the log the heatmap is drawn from. VLC
  has no equivalent — scripts there are installed into the application, not
  handed to it at launch — but it does have a web interface, and that reports
  the playhead. So laev starts VLC with that interface bound to localhost on a
  random port behind a random password, and polls it on the same five-second
  cadence the Lua script uses, writing the same three files by the same rules.

  Which means everything downstream carries on working unchanged — resume,
  Up Next, the watched ticks, the stats, the heatmap, MyAnimeList scrobbling —
  because all of it reads those files and none of it knows which player wrote
  them.

  Two things don't come across, both of them mpv scripts rather than playback:
  skipping intros, and the stinger prompt. laev says so when you switch.
  """

  @poll 5_000

  # The cadence is the mpv script's; tests drive it faster so a play can be
  # followed in a second rather than in half a minute.
  defp poll_interval, do: Laev.Scope.get(:vlc_poll_ms, @poll)
  # What five seconds of real playback can advance the playhead by. Anything
  # beyond it is a seek, which is re-watching or skipping, not watching.
  @budget 9.0
  # Matches the Lua: a position under this is the beginning, not a place.
  @floor_seconds 30

  @doc """
  Arguments for a VLC launch: the web interface it is tracked through, the
  language preferences, any external subtitle, and where to start.

  Returns `{args, resume_at, tracking}` — `tracking` is what `track/3` needs to
  find the interface again.
  """
  def launch_args(ctx, extra_args) do
    port = free_port()
    password = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    args =
      [
        "--extraintf=http",
        "--http-host=127.0.0.1",
        "--http-port=#{port}",
        "--http-password=#{password}",
        # Quit when the file ends rather than sitting on a black window, so
        # "is it still playing?" has an honest answer.
        "--play-and-exit"
      ] ++ language_args() ++ translate(extra_args) ++ start_args(ctx)

    {args, resume_at(ctx), %{port: port, password: password}}
  end

  @doc """
  Follow the playhead for as long as VLC is up, writing what mpv's script
  would have written. Returns immediately; the watching happens in its own
  process, which ends when VLC does.
  """
  def track(nil, _tracking), do: :ok

  def track(ctx, %{port: port, password: password}) do
    Laev.Scope.spawn(fn ->
      # VLC's interface takes a moment to bind. Until it answers there is
      # nothing to ask it about.
      Process.sleep(Laev.Scope.get(:vlc_settle_ms, 3_000))
      {watched, _skipped} = totals = load_played(ctx)
      follow(ctx, port, password, nil, totals, watched, false, 0)
    end)

    :ok
  end

  # ── the loop ──────────────────────────────────────────────────────

  defp follow(ctx, port, password, last_pos, {watched, skipped}, logged, saw_early, misses) do
    case status(port, password) do
      {:ok, position, duration} ->
        {watched, skipped} = accumulate(last_pos, position, {watched, skipped})
        saw_early = saw_early or (duration > 0 and position < duration * 0.5)
        # What today's log is owed since the last sample — held here rather
        # than worked out from the file, which is the record of this sample by
        # the time it would be read.
        earned = trunc(watched) - trunc(logged)

        Laev.Position.record(ctx, %{
          position: position,
          duration: duration,
          watched: watched,
          skipped: skipped,
          finished: saw_early and duration > 0 and position >= duration * 0.85,
          floor: @floor_seconds,
          log_seconds: earned
        })

        logged = if earned >= 1, do: watched, else: logged

        Process.sleep(poll_interval())
        follow(ctx, port, password, position, {watched, skipped}, logged, saw_early, 0)

      :gone ->
        # Two misses in a row is VLC gone, not a slow answer. The last write
        # stands as where you got to.
        unless misses >= 1 do
          Process.sleep(poll_interval())
          follow(ctx, port, password, last_pos, {watched, skipped}, logged, saw_early, misses + 1)
        end

        :ok
    end
  end

  # Same rule as the Lua script: forward by about a tick is watching, more is
  # skipping, backwards is re-watching and already paid for.
  defp accumulate(nil, _position, totals), do: totals

  defp accumulate(last, position, {watched, skipped}) do
    delta = position - last

    cond do
      delta > 0 and delta <= @budget -> {watched + delta, skipped}
      delta > @budget -> {watched, skipped + delta}
      true -> {watched, skipped}
    end
  end

  defp status(port, password) do
    case Req.get("http://127.0.0.1:#{port}/requests/status.xml",
           auth: {:basic, ":#{password}"},
           retry: false,
           receive_timeout: 4_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        with time when is_integer(time) <- tag(body, "time"),
             length when is_integer(length) <- tag(body, "length") do
          {:ok, time * 1.0, length * 1.0}
        else
          _ -> :gone
        end

      _ ->
        :gone
    end
  rescue
    _ -> :gone
  end

  # The interface answers a small, regular XML document; the two numbers it is
  # asked for are plain integer elements.
  defp tag(body, name) do
    case Regex.run(~r{<#{name}>(-?\d+)</#{name}>}, body) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp load_played(ctx) do
    case Laev.Position.played(ctx) do
      %{watched: watched, skipped: skipped} -> {watched * 1.0, skipped * 1.0}
      _ -> {0.0, 0.0}
    end
  end

  # ── launch arguments ──────────────────────────────────────────────

  defp start_args(ctx) do
    case Laev.Position.saved_position(ctx) do
      seconds when is_integer(seconds) and seconds > 0 -> ["--start-time=#{seconds}"]
      _ -> []
    end
  end

  defp resume_at(ctx) do
    case Laev.Position.saved_position(ctx) do
      seconds when is_integer(seconds) and seconds > 0 -> Laev.Stats.duration(seconds)
      _ -> nil
    end
  end

  defp language_args do
    audio =
      case Laev.Config.lang() do
        lang when is_binary(lang) and lang != "" -> ["--audio-language=#{Laev.Player.lang_codes(lang)}"]
        _ -> []
      end

    subs =
      case Laev.Config.subs_lang() do
        lang when is_binary(lang) and lang != "" -> ["--sub-language=#{Laev.Player.lang_codes(lang)}"]
        _ -> []
      end

    audio ++ subs
  end

  # The subtitle file is the one piece of the mpv argument list that means
  # something to VLC too; everything else there is a script or a script option.
  defp translate(args) do
    for "--sub-file=" <> path <- args, do: "--sub-file=#{path}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
