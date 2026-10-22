defmodule Laev.VlcTrackerTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, VLC}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-vlc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    File.mkdir_p!(Path.join(dir, "played"))
    previous = Application.get_env(:laev, :data_dir)
    Application.put_env(:laev, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev, :data_dir, previous),
        else: Application.delete_env(:laev, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp ctx, do: %{type: "movie", tmdb_id: 1597, season: nil, episode: nil}

  defp position(dir), do: File.read!(Path.join([dir, "positions", "movie-1597"])) |> String.trim()
  defp played(dir), do: File.read!(Path.join([dir, "played", "movie-1597"])) |> String.trim()

  # The rules are the mpv script's, applied from outside the player: anything
  # in the first half-minute is the beginning rather than a place to return to.
  test "an early position is not a place to come back to", %{dir: dir} do
    Position.record(ctx(), %{position: 12.0, duration: 6000.0, watched: 12.0, skipped: 0.0, finished: false, floor: 30})

    assert position(dir) == "0"
  end

  test "a real position is saved, and resumes", %{dir: dir} do
    Position.record(ctx(), %{position: 1847.0, duration: 6000.0, watched: 1847.0, skipped: 0.0, finished: false, floor: 30})

    assert position(dir) == "1847"
    assert Position.saved_position(ctx()) == 1847
  end

  test "past the end is the watched marker, not a number", %{dir: dir} do
    Position.record(ctx(), %{position: 5300.0, duration: 6000.0, watched: 5300.0, skipped: 0.0, finished: true, floor: 30})

    assert position(dir) == "done"
    assert Position.finished?(ctx())
  end

  # Watched-versus-skipped is what the stats are built from, so VLC has to
  # count it the way the script does.
  test "seconds watched and seconds seeked past are kept apart", %{dir: dir} do
    Position.record(ctx(), %{position: 600.0, duration: 6000.0, watched: 595.0, skipped: 120.0, finished: false, floor: 30})

    assert played(dir) == "595 120"
    assert %{watched: 595, skipped: 120} = Position.played(ctx())
  end

  # The heatmap is drawn from a day log the player appends to as it goes.
  test "the day's log grows by what was watched since the last sample" do
    Position.record(ctx(), %{position: 300.0, duration: 6000.0, watched: 300.0, skipped: 0.0, finished: false, floor: 30, log_seconds: 300})
    Position.record(ctx(), %{position: 600.0, duration: 6000.0, watched: 600.0, skipped: 0.0, finished: false, floor: 30, log_seconds: 300})

    today = Date.to_string(Laev.Days.today())
    lines = Position.log_file() |> File.read!() |> String.split("\n", trim: true)

    assert Enum.all?(lines, &String.starts_with?(&1, today))
    total = Enum.reduce(lines, 0, fn line, sum -> sum + (line |> String.split(" ") |> List.last() |> String.to_integer()) end)

    assert total == 600, "every second counted once, not twice"
  end

  # The whole loop, against VLC's actual interface shape: laev polls it, parses
  # the two numbers it needs, and writes the position down. Nothing here knows
  # it isn't VLC.
  test "following a real status feed records the play", %{dir: dir} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    # The playhead as VLC would report it: moving at one second per second.
    positions = [100, 105, 110]

    server =
      spawn(fn ->
        Enum.each(positions, fn seconds ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          _request = :gen_tcp.recv(socket, 0, 2_000)

          body =
            "<root><time>#{seconds}</time><length>6000</length><state>playing</state></root>"

          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body)
          :gen_tcp.close(socket)
        end)
      end)

    Application.put_env(:laev, :vlc_poll_ms, 40)
    Application.put_env(:laev, :vlc_settle_ms, 0)
    on_exit(fn ->
      Application.delete_env(:laev, :vlc_poll_ms)
      Application.delete_env(:laev, :vlc_settle_ms)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    VLC.track(ctx(), %{port: port, password: "secret"})
    Process.sleep(600)

    assert position(dir) == "110", "the last position VLC reported"
    assert %{watched: watched} = Position.played(ctx())
    assert watched == 10, "two five-second ticks of real playback"
  end

  # The arguments VLC is actually launched with: its web interface bound to
  # localhost behind a password, and nothing of mpv's but the subtitle file.
  test "the launch arguments are VLC's, not mpv's" do
    {args, _resume, tracking} =
      VLC.launch_args(ctx(), ["--sub-file=/tmp/subs.srt", "--script=/some/laev.lua", "--script-opts-append=laev-file=x"])

    assert "--sub-file=/tmp/subs.srt" in args
    refute Enum.any?(args, &String.starts_with?(&1, "--script"))
    assert "--http-host=127.0.0.1" in args, "the interface must not be reachable off this machine"
    assert Enum.any?(args, &String.starts_with?(&1, "--http-password="))
    assert tracking.port > 0
  end

  test "a saved position becomes VLC's start time" do
    Position.record(ctx(), %{position: 1847.0, duration: 6000.0, watched: 1847.0, skipped: 0.0, finished: false, floor: 30})
    {args, resume, _} = VLC.launch_args(ctx(), [])

    assert "--start-time=1847" in args
    assert resume == "30m"
  end
end
