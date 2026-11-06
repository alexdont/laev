defmodule Laev.TickIntegrityTest do
  use ExUnit.Case, async: false

  alias Laev.{Days, Position, Scope, Stints, Sync}

  # The tick log and the day log are written from the same call and must agree:
  # the day log says how much a day held, the tick log says what filled it. A
  # real account had five days in one and nothing in the other.
  #
  # Two mechanisms were losing ticks, and both are here. `open_tail/1` computed
  # the last line's offset as `size - byte_size(last) - 1`, which is only right
  # for a file ending in a newline — for one that doesn't, it truncated a byte
  # early and glued two entries into an unreadable line. And the extend path is
  # read-tail-truncate-write, which two writers at once could interleave.

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-ticks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev, :data_dir)
    Application.put_env(:laev, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev, :data_dir, previous),
        else: Application.delete_env(:laev, :data_dir)
    end)

    {:ok, dir: dir, scope: Scope.new(dir, %{}), ctx: %{type: "tv", tmdb_id: 110_316, season: 2, episode: 1}}
  end

  defp tick_seconds, do: Stints.ticks() |> Enum.map(fn {_at, _key, s} -> s end) |> Enum.sum()
  defp day_seconds, do: Days.totals() |> Map.values() |> Enum.sum()
  defp raw(path), do: File.read(path) |> case(do: ({:ok, b} -> b; _ -> ""))

  test "a hundred reports leave every second readable in both logs", %{ctx: ctx} do
    for i <- 1..100 do
      Position.record(ctx, %{position: i * 5, watched: i * 5, skipped: 0, log_seconds: 5, reported: (i - 1) * 5})
    end

    assert tick_seconds() == 500
    assert day_seconds() == 500
  end

  # The file sync used to leave behind: no final newline. Extending its last
  # line must not take the newline off the line before it.
  test "the tail merge does not glue onto an unterminated file", %{ctx: ctx} do
    path = Stints.log_file()
    File.write!(path, "1793000000 movie-603 5\n1793000100 tv-110316-s2e1 7")

    Position.record(ctx, %{position: 10, watched: 10, skipped: 0, log_seconds: 3, reported: 5})

    lines = raw(path) |> String.split("\n", trim: true)

    assert length(lines) == 2, "the merge rewrote more than the line it was merging:\n#{raw(path)}"
    assert Enum.at(lines, 0) == "1793000000 movie-603 5"
    assert tick_seconds() == 15, "5 + 7 + 3, none of it glued into an unreadable line"
    assert String.ends_with?(raw(path), "\n"), "and the file it leaves behind is terminated"
  end

  test "an unterminated single-line file is extended, not doubled", %{ctx: ctx} do
    File.write!(Stints.log_file(), "1793000100 tv-110316-s2e1 7")

    Position.record(ctx, %{position: 10, watched: 10, skipped: 0, log_seconds: 3, reported: 5})

    assert tick_seconds() == 10
  end

  test "reports with a sync pull between them lose nothing", %{ctx: ctx, dir: dir} do
    ticks = Path.join(dir, "ticks")

    for i <- 1..20 do
      Position.record(ctx, %{position: i * 5, watched: i * 5, skipped: 0, log_seconds: 5, reported: (i - 1) * 5})

      if rem(i, 5) == 0 do
        # A pull arriving mid-session, carrying this device's own log as the
        # server last saw it — which is always behind what is here.
        Sync.apply_dir(ticks, %{"#{Position.device_id()}.log" => %{"data" => "1793000000 movie-603 5"}}, :log)
      end
    end

    assert tick_seconds() == 100, "a pull overwrote ticks this device had and the server did not"
    assert day_seconds() == 100
  end

  # Only this device appends to its own log, so a pulled copy can be behind it
  # but never ahead. Another device's log is a different matter: it is the only
  # copy this machine will ever have, and the remote one is the truth.
  describe "what a pull may replace" do
    test "not this device's own log", %{dir: dir} do
      path = Path.join([dir, "ticks", "#{Position.device_id()}.log"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "1793000000 movie-603 5\n1793000100 movie-603 9\n")

      Sync.apply_dir(Path.join(dir, "ticks"), %{"#{Position.device_id()}.log" => %{"data" => "1793000000 movie-603 5"}}, :log)

      assert raw(path) == "1793000000 movie-603 5\n1793000100 movie-603 9\n"
    end

    test "but a pull that genuinely extends it is taken", %{dir: dir} do
      path = Path.join([dir, "ticks", "#{Position.device_id()}.log"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "1793000000 movie-603 5\n")

      Sync.apply_dir(
        Path.join(dir, "ticks"),
        %{"#{Position.device_id()}.log" => %{"data" => "1793000000 movie-603 5\n1793000100 movie-603 9"}},
        :log
      )

      assert raw(path) == "1793000000 movie-603 5\n1793000100 movie-603 9\n"
    end

    test "and a machine with no log of its own gets its history back", %{dir: dir} do
      path = Path.join([dir, "ticks", "#{Position.device_id()}.log"])

      Sync.apply_dir(Path.join(dir, "ticks"), %{"#{Position.device_id()}.log" => %{"data" => "1793000000 movie-603 5"}}, :log)

      assert raw(path) == "1793000000 movie-603 5\n"
    end

    test "another device's log is always the remote copy", %{dir: dir} do
      path = Path.join([dir, "ticks", "other.log"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "1793000000 movie-603 5\n1793000100 movie-603 9\n")

      Sync.apply_dir(Path.join(dir, "ticks"), %{"other.log" => %{"data" => "1793000000 movie-603 5"}}, :log)

      assert raw(path) == "1793000000 movie-603 5\n"
    end

    test "a tombstone never deletes this device's own log", %{dir: dir} do
      own = Path.join([dir, "ticks", "#{Position.device_id()}.log"])
      other = Path.join([dir, "ticks", "other.log"])
      File.mkdir_p!(Path.dirname(own))
      File.write!(own, "1793000000 movie-603 5\n")
      File.write!(other, "1793000000 movie-603 5\n")

      Sync.apply_dir(
        Path.join(dir, "ticks"),
        %{
          "#{Position.device_id()}.log" => %{"data" => "", "deleted" => true},
          "other.log" => %{"data" => "", "deleted" => true}
        },
        :log
      )

      assert File.exists?(own), "a device that hasn't got this file cannot delete it for the one that writes it"
      refute File.exists?(other)
    end
  end

  # The merge reads the tail, truncates it and writes it back. Two of those at
  # once could both read the same tail and the second could overwrite the first.
  test "two writers at once lose nothing", %{scope: scope} do
    keys = ["tv-110316-s2e1", "movie-603"]

    tasks =
      for n <- 1..2 do
        Task.async(fn ->
          Scope.run(scope, fn ->
            for i <- 1..50 do
              Stints.tick(Enum.at(keys, rem(n + i, 2)), 1, 1_793_000_000 + i * 2)
            end
          end)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 30_000))

    Scope.run(scope, fn ->
      assert tick_seconds() == 100, "ticks written at the same time overwrote each other"
    end)
  end
end
