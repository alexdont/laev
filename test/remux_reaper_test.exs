defmodule Laev.RemuxReaperTest do
  use ExUnit.Case, async: false

  alias Laev.Remux.Reaper

  # A conversion's ffmpeg used to run for its full two hours whatever became of
  # whoever asked for it: a closed tab left a core burning, and four of them put
  # a host at a load average near 150. Whatever serves the segments calls
  # `Laev.Remux.touch/1`, and the sweep stops what nobody has asked for.
  #
  # Two clocks, because they are two different situations. One nobody has
  # fetched in ten minutes is abandoned. One that has written no playable
  # playlist at all after two is stuck — a dead URL, a stream wanting a key, a
  # full disk — and there is nothing to abandon yet.

  setup do
    # The reaper is started by the application; these drive `sweep/2` directly
    # so no timer has to be waited on.
    running = Application.get_env(:laev, :remux_running_stub)

    on_exit(fn ->
      if running,
        do: Application.put_env(:laev, :remux_running_stub, running),
        else: Application.delete_env(:laev, :remux_running_stub)
    end)

    :ok
  end

  test "touch records when a conversion was last asked for" do
    id = "0123456789abcdef"
    assert Reaper.touch(id) == :ok
    assert is_integer(Reaper.last_touch(id))
  end

  test "an id never touched has no record" do
    assert Reaper.last_touch("ffffffffffffffff") == nil
  end

  test "touching something that is not an id is not a crash" do
    assert Reaper.touch(nil) == :ok
    assert Reaper.touch(42) == :ok
  end

  describe "what the sweep decides about one conversion" do
    @idle 10 * 60
    @never_ready 2 * 60

    test "a conversion being fetched from is left alone" do
      assert Reaper.verdict(30, true, @idle, @never_ready) == :keep
      assert Reaper.verdict(@idle - 1, true, @idle, @never_ready) == :keep
    end

    test "one nobody has fetched from inside the window is stopped" do
      assert Reaper.verdict(@idle + 1, true, @idle, @never_ready) == :stop
    end

    # The clock starts the first time the sweep sees it, so a slow first
    # segment is not mistaken for nobody watching.
    test "one that has written nothing yet is given its two minutes" do
      assert Reaper.verdict(5, false, @idle, @never_ready) == :keep
      assert Reaper.verdict(@never_ready - 1, false, @idle, @never_ready) == :keep
    end

    test "and stopped after them, rather than burning a core for eight more" do
      assert Reaper.verdict(@never_ready + 1, false, @idle, @never_ready) == :stop
    end

    # The two clocks are independent: something playable is judged on whether
    # anybody is fetching it, not on how long it took to get going.
    test "a slow starter that did get going keeps the full idle window" do
      assert Reaper.verdict(@never_ready + 1, true, @idle, @never_ready) == :keep
    end
  end

  test "and a sweep with nothing running never raises" do
    assert Reaper.sweep(0, 0) == :ok
    assert Reaper.sweep(10 * 60, 2 * 60) == :ok
  end
end
