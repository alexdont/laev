defmodule Laev.StatsTest do
  use ExUnit.Case, async: false

  alias Laev.Stats

  # Runtimes are pre-seeded into the cache so nothing here touches TMDB: an
  # entry already in `runtimes.json` is never looked up.
  setup do
    dir = Path.join(System.tmp_dir!(), "laev-stats-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp position(dir, name, body), do: File.write!(Path.join([dir, "positions", name]), body)
  defp played(dir, name, body) do
    File.mkdir_p!(Path.join(dir, "played"))
    File.write!(Path.join([dir, "played", name]), body)
  end

  defp runtimes(dir, map), do: File.write!(Path.join(dir, "runtimes.json"), Jason.encode!(map))

  test "a film marked watched by hand is worth its runtime", %{dir: dir} do
    position(dir, "movie-1122573", "seen")
    runtimes(dir, %{"movie-1122573" => 5820})

    stats = Stats.all_time()

    # The whole point: ctrl-w in search says you watched it, so the total moves.
    assert stats.seconds == 5820
    assert stats.films == 1
    assert stats.marked == 1
    assert stats.unknown == 0
  end

  test "a finished play and a hand mark are worth the same", %{dir: dir} do
    position(dir, "movie-1", "done")
    position(dir, "movie-2", "seen")
    runtimes(dir, %{"movie-1" => 6000, "movie-2" => 6000})

    assert Stats.all_time().seconds == 12_000
  end

  test "a part-watched entry is worth the seconds it reached, not its runtime", %{dir: dir} do
    position(dir, "movie-1", "900")
    runtimes(dir, %{"movie-1" => 6000})

    stats = Stats.all_time()
    assert stats.seconds == 900
    assert [%{started: 1, finished: 0}] = stats.titles
  end

  test "an entry with no runtime is watched but untimed, and says so", %{dir: dir} do
    position(dir, "movie-1", "seen")
    runtimes(dir, %{"movie-1" => "unknown"})

    stats = Stats.all_time()
    assert stats.seconds == 0
    assert stats.unknown == 1
  end

  test "marking a whole series is watched, but never guesses hours", %{dir: dir} do
    position(dir, "tv-1399", "seen")
    runtimes(dir, %{"tv-1399" => 3420})

    # laev has no idea how many of its 73 episodes you actually sat through.
    assert Stats.all_time().seconds == 0
  end

  test "episodes borrow their show's runtime and count their show once", %{dir: dir} do
    for e <- 1..3, do: position(dir, "tv-500-e#{e}", "done")
    position(dir, "tv-600-s1e1", "seen")
    runtimes(dir, %{"tv-500" => 1440, "tv-600" => 1440})

    stats = Stats.all_time()
    assert stats.seconds == 4 * 1440
    assert stats.episodes == 4
    assert stats.shows == 2
  end

  test "a measured play beats the runtime estimate, and reports what was skipped", %{dir: dir} do
    position(dir, "movie-1", "done")
    played(dir, "movie-1", "3000 600")
    runtimes(dir, %{"movie-1" => 6000})

    stats = Stats.all_time()
    assert stats.seconds == 3000, "measured seconds should win over the runtime"
    assert stats.skipped == 600
    assert stats.measured == 1
  end

  test "duration reads as hours and minutes" do
    assert Stats.duration(43_440) == "12h 04m"
    assert Stats.duration(2880) == "48m"
    assert Stats.duration(0) == "0m"
  end
end
