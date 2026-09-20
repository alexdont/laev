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

  defp run(mode) do
    dir = Path.join(System.tmp_dir!(), "laev-lua-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    script = Path.join(dir, "position.lua")
    File.write!(script, Laev.Position.script_source())
    paths = Enum.map(~w(pos tracks played), &Path.join(dir, &1))

    {out, status} = System.cmd("lua", [@harness, script] ++ paths ++ [mode], stderr_to_stdout: true)

    %{status: status, out: out, position: read(Enum.at(paths, 0)), played: read(Enum.at(paths, 2))}
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

  test "stopping partway leaves the second reached, not a marker" do
    assert {seconds, ""} = Integer.parse(run("seek").position)
    assert seconds > 3700 and seconds < 3800
  end
end
