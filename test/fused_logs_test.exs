defmodule Laev.FusedLogsTest do
  use ExUnit.Case, async: false

  alias Laev.{Days, Scope, Stints, Sync}

  # Sync used to break the append-only logs it carried. `read_dir/1` trims what
  # it reads, so a log reached the bundle without its final newline, and a pull
  # wrote it back that way. Everything that writes those files only appends, so
  # the next line fused onto the last one and the pair parsed as neither:
  #
  #     1793450449 movie-1283515 11793460753 tv-110316-s2e1 1
  #     2026-10-31 12026-11-01 1
  #
  # The first lost both ticks. The second was worse — `Integer.parse/1` stops
  # happily at the first non-digit, so it read as 12,026 seconds on the 31st.
  # Measured on a real account: 64 such lines claiming 4,470 hours.

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-fused-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev, :data_dir)
    Application.put_env(:laev, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev, :data_dir, previous),
        else: Application.delete_env(:laev, :data_dir)
    end)

    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  describe "a pulled log can be appended to" do
    test "a log arrives newline-terminated, so the next line is its own", %{dir: dir, scope: scope} do
      ticks = Path.join(dir, "ticks")
      Sync.apply_dir(ticks, %{"other.log" => %{"data" => "1793958841 movie-1 5"}}, :log)

      assert File.read!(Path.join(ticks, "other.log")) == "1793958841 movie-1 5\n"

      Scope.run(scope, fn ->
        Stints.tick("movie-2", 7, 1_793_958_900)

        assert Stints.ticks() == [{1_793_958_841, "movie-1", 5}, {1_793_958_900, "movie-2", 7}]
      end)
    end

    test "and so does a watched log", %{dir: dir} do
      watched = Path.join(dir, "watched")
      Sync.apply_dir(watched, %{"other.log" => %{"data" => "2026-10-31 60"}}, :log)

      assert File.read!(Path.join(watched, "other.log")) == "2026-10-31 60\n"
    end

    test "a log already terminated is not given a second newline", %{dir: dir} do
      ticks = Path.join(dir, "ticks")
      Sync.apply_dir(ticks, %{"a.log" => %{"data" => "1793958841 movie-1 5\n"}}, :log)
      assert File.read!(Path.join(ticks, "a.log")) == "1793958841 movie-1 5\n"
    end

    # The newline belongs to logs alone. A position, a hold or a track is one
    # value in one file, and nothing appends to it.
    test "single-record files are written exactly as they arrived", %{dir: dir} do
      positions = Path.join(dir, "positions")
      Sync.apply_dir(positions, %{"movie-603" => %{"data" => "1312.5"}})

      assert File.read!(Path.join(positions, "movie-603")) == "1312.5"
    end

    test "an empty record stays empty, whatever its shape", %{dir: dir} do
      d = Path.join(dir, "ticks")
      Sync.apply_dir(d, %{"empty.log" => %{"data" => ""}}, :log)
      assert File.read!(Path.join(d, "empty.log")) == ""
    end
  end

  describe "logs already damaged still read correctly" do
    test "a fused tick line is two ticks again", %{dir: dir, scope: scope} do
      write(dir, "ticks", """
      1793325868 mal-63832-e1 351793401345 movie-1765072 2
      1793958987 tv-289517-s1e8 41793959117 tv-289517-s1e8 2
      """)

      Scope.run(scope, fn ->
        assert Stints.ticks() == [
                 {1_793_325_868, "mal-63832-e1", 35},
                 {1_793_401_345, "movie-1765072", 2},
                 {1_793_958_987, "tv-289517-s1e8", 4},
                 {1_793_959_117, "tv-289517-s1e8", 2}
               ]
      end)
    end

    test "and the seconds it used to drop are in the sessions", %{dir: dir, scope: scope} do
      write(dir, "ticks", "1793461584 tv-110316-s2e1 891793464623 tv-110316-s2e1 2\n")

      Scope.run(scope, fn ->
        assert Enum.sum(Enum.map(Stints.sessions(), & &1.seconds)) == 91
      end)
    end

    test "a healthy log reads as it always did", %{dir: dir, scope: scope} do
      write(dir, "ticks", "1793000000 movie-603 5\n1793000100 movie-603 7\n")

      Scope.run(scope, fn ->
        assert Stints.ticks() == [{1_793_000_000, "movie-603", 5}, {1_793_000_100, "movie-603", 7}]
      end)
    end

    test "and a line laev did not write is still skipped", %{dir: dir, scope: scope} do
      write(dir, "ticks", """
      nonsense
      1793000000 movie-603
      1793000000 movie-603 five
      1793000000 movie-603 5
      """)

      Scope.run(scope, fn ->
        assert Stints.ticks() == [{1_793_000_000, "movie-603", 5}]
      end)
    end

    test "a fused day line is two days again", %{dir: dir} do
      write_own(dir, "2026-10-31 12026-11-01 1\n2026-11-01 59\n")

      assert Days.totals() == %{~D[2026-10-31] => 1, ~D[2026-11-01] => 60}
    end

    test "a day cannot hold more than a day, and such a line is damage", %{dir: dir} do
      # What compaction baked in when it folded fused lines with the lenient
      # parser. The original seconds are gone; the fiction is not kept.
      write_own(dir, "2026-09-30 194322026\n2026-09-30 6\n")

      assert Days.totals() == %{~D[2026-09-30] => 6}
    end

    test "a whole day exactly is still a day", %{dir: dir} do
      write_own(dir, "2026-09-30 86400\n")
      assert Days.totals() == %{~D[2026-09-30] => 86_400}
    end

    test "and an unparsable day line is skipped as before", %{dir: dir} do
      write_own(dir, "not-a-date 5\n2026-09-30 nine\n2026-09-30 9\n")
      assert Days.totals() == %{~D[2026-09-30] => 9}
    end
  end

  defp write(dir, collection, body) do
    path = Path.join([dir, collection, "device.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp write_own(dir, body) do
    path = Laev.Position.log_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    _ = dir
    :ok
  end
end
