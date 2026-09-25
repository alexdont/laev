defmodule Laev.QuietTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Laev.Quiet

  setup do
    on_exit(fn -> :persistent_term.put({Quiet, :held}, 0) end)
    :persistent_term.put({Quiet, :held}, 0)
    :ok
  end

  test "a note prints when nothing owns the screen" do
    assert capture_io(:stderr, fn -> Quiet.puts("hello") end) =~ "hello"
  end

  test "a note is dropped while a picker owns the screen" do
    out = capture_io(:stderr, fn -> Quiet.hold(fn -> Quiet.puts("hello") end) end)

    assert out == ""
  end

  test "the screen is released again afterwards" do
    Quiet.hold(fn -> :ok end)

    refute Quiet.held?()
    assert capture_io(:stderr, fn -> Quiet.puts("after") end) =~ "after"
  end

  test "a picker that raises still releases the screen" do
    assert_raise RuntimeError, fn -> Quiet.hold(fn -> raise "boom" end) end

    refute Quiet.held?()
  end

  test "a picker inside a picker keeps the screen until both are done" do
    Quiet.hold(fn ->
      Quiet.hold(fn -> :ok end)
      # The inner one closed; the outer still owns the screen.
      assert Quiet.held?()
      assert capture_io(:stderr, fn -> Quiet.puts("nope") end) == ""
    end)

    refute Quiet.held?()
  end

  test "hold returns what the picker returned" do
    assert Quiet.hold(fn -> {:ok, :chosen} end) == {:ok, :chosen}
  end

  test "another process is silenced too — that is the whole point" do
    out =
      capture_io(:stderr, fn ->
        Quiet.hold(fn ->
          # A background sync push lands mid-frame, from its own process.
          task = Task.async(fn -> Quiet.puts("↻ watched: 2 change(s) synced") end)
          Task.await(task)
        end)
      end)

    assert out == ""
  end
end
