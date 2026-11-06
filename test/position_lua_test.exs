defmodule Laev.PositionLuaTest do
  use ExUnit.Case, async: true

  # The tracker only ever runs inside mpv, so nothing in Elixir can tell you
  # it died on load — the symptom is silence: no positions, no watched marks,
  # no track memory, for an entire film. These run the real script under a
  # Lua interpreter with a stubbed mpv and let any error fail the test.
  @moduletag :lua

  @harness Path.join(__DIR__, "support/mpv_harness.lua")

  setup_all do
    unless System.find_executable("lua"), do: raise("lua is needed for these tests")
    :ok
  end

  defp run(mode, setup \\ []) do
    dir = Path.join(System.tmp_dir!(), "laev-lua-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    script = Path.join(dir, "position.lua")
    File.write!(script, Laev.Position.script_source())
    paths = Enum.map(~w(pos tracks played log ticks), &Path.join(dir, &1))

    # What the files already hold when mpv starts — a resume has seconds in
    # the played file, and a log damaged by an older laev has no final newline.
    for {which, body} <- setup do
      File.write!(Path.join(dir, to_string(which)), body)
    end

    args = [@harness, script] ++ paths ++ ["tv-110316-s2e1", mode]
    {out, status} = System.cmd("lua", args, stderr_to_stdout: true)

    %{
      status: status,
      out: out,
      position: read(Enum.at(paths, 0)),
      played: read(Enum.at(paths, 2)),
      log: read(Enum.at(paths, 3)),
      ticks: read(Enum.at(paths, 4)),
      ticks_raw: File.read(Enum.at(paths, 4)) |> case(do: ({:ok, b} -> b; _ -> "")),
      log_raw: File.read(Enum.at(paths, 3)) |> case(do: ({:ok, b} -> b; _ -> ""))
    }
  end

  defp seconds_of(nil), do: 0

  defp seconds_of(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(0, fn line, sum -> sum + (line |> String.split(" ") |> List.last() |> String.to_integer()) end)
  end

  defp read(path), do: with({:ok, body} <- File.read(path), do: String.trim(body), else: (_ -> nil))

  test "a full playback runs the script through without raising" do
    result = run("full")

    # The bug this exists for: a call placed before its `local function` is a
    # nil global, and mpv takes the whole script down on the first event.
    refute result.out =~ "attempt to call a nil value",
           "the tracker raised inside a handler:\n#{result.out}"

    assert result.status == 0, result.out
  end

  test "watching to the end leaves the watched marker" do
    assert run("full").position == "done"
  end

  test "a full playback records the time as watched, not skipped" do
    assert [watched, skipped] = run("full").played |> String.split(" ") |> Enum.map(&String.to_integer/1)

    assert watched >= 5900, "expected roughly the whole 6000s as watched, got #{watched}"
    assert watched <= 6000
    assert skipped == 0
  end

  test "a seek forward is counted as skipped, not watched" do
    assert [watched, skipped] = run("seek").played |> String.split(" ") |> Enum.map(&String.to_integer/1)

    # A minute watched, an hour jumped, a minute watched.
    assert_in_delta watched, 120, 5
    assert_in_delta skipped, 3600, 5
  end

  test "the day log records what was watched, dated, as it happens" do
    lines = run("full").log |> String.split("\n", trim: true)

    # The script stamps local dates, so the check has to read the same clock:
    # between midnight and UTC's, the two disagree and this would fail nightly.
    today = Date.to_iso8601(Laev.Days.today())
    assert length(lines) > 1, "the log should be appended to as it plays, not written once"
    assert Enum.all?(lines, &String.starts_with?(&1, today)), "every line carries the day it happened on"

    total = Enum.reduce(lines, 0, fn line, sum -> sum + (line |> String.split(" ") |> List.last() |> String.to_integer()) end)
    # The whole 6000s film, give or take the sampling.
    assert_in_delta total, 6000, 60
  end

  test "a seek is not logged as time watched" do
    total =
      run("seek").log
      |> String.split("\n", trim: true)
      |> Enum.reduce(0, fn line, sum -> sum + (line |> String.split(" ") |> List.last() |> String.to_integer()) end)

    # Two minutes watched around an hour-long jump; the jump is not watching.
    assert_in_delta total, 120, 10
  end

  test "stopping partway leaves the second reached, not a marker" do
    assert {seconds, ""} = Integer.parse(run("seek").position)
    assert seconds > 3700 and seconds < 3800
  end

  # The tick log is the per-title timeline: what filled a day, not just how
  # much of it was filled. It was written only by laev's own side, which for an
  # mpv play is not running — laev launches the player and goes. So every mpv
  # play was missing from it, while the day log beside it had the day. On a real
  # account that was five consecutive days of watching with no trace of what.
  describe "the tick log, which only the player can keep" do
    test "a playback writes ticks, keyed and stamped" do
      ticks = run("full").ticks |> String.split("\n", trim: true)

      assert ticks != [], "an mpv play has to leave ticks of its own"

      for line <- ticks do
        assert [at, "tv-110316-s2e1", seconds] = String.split(line, " ")
        assert {at, ""} = Integer.parse(at)
        assert at > 1_700_000_000, "a tick carries the epoch it happened at"
        assert {n, ""} = Integer.parse(seconds)
        assert n >= 1
      end
    end

    test "and they add up to what the day log says" do
      result = run("full")

      assert_in_delta seconds_of(result.ticks), seconds_of(result.log), 2
      assert_in_delta seconds_of(result.ticks), 6000, 60
    end

    # A minute at a time, not a line per five-second sample: a tick is a
    # stretch of watching, and the log travels between devices.
    test "a tick is a minute of watching, not a sample" do
      result = run("full")
      ticks = String.split(result.ticks, "\n", trim: true)
      days = String.split(result.log, "\n", trim: true)

      assert length(ticks) < length(days) / 5,
             "#{length(ticks)} ticks for #{length(days)} day lines is one per sample"
    end

    test "a seek is not watched, here either" do
      assert_in_delta seconds_of(run("seek").ticks), 120, 10
    end

    # Appending to a log that lost its final newline is what glued two entries
    # into one unreadable line. The player writes the newline it is missing.
    test "a log left unterminated is not appended onto" do
      result =
        run("full",
          ticks: "1793000000 movie-603 5",
          log: "2026-01-01 5"
        )

      assert result.ticks_raw |> String.split("\n", trim: true) |> Enum.at(0) ==
               "1793000000 movie-603 5"

      assert result.log_raw |> String.split("\n", trim: true) |> Enum.at(0) == "2026-01-01 5"
      assert String.ends_with?(result.ticks_raw, "\n")
    end
  end

  # `load_played` assigned `logged` before the `local logged` existed, which in
  # Lua writes a global of that name while the logging functions read the local.
  # So a resumed film started from `logged = 0` with `watched` already at
  # whatever earlier sessions had earned, and the first save wrote all of it to
  # *today* — 40 minutes of yesterday's film counted again this evening.
  test "resuming a film does not re-log the seconds it already logged" do
    result = run("resume", played: "900 0")

    assert seconds_of(result.log) < 60,
           "only the new seconds belong to today, got #{seconds_of(result.log)}"

    assert seconds_of(result.ticks) < 60
    assert [watched, _skipped] = result.played |> String.split(" ") |> Enum.map(&String.to_integer/1)
    assert watched >= 900, "the earlier session is still part of what was watched"
  end
end
