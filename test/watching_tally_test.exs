defmodule Laev.WatchingTallyTest do
  use ExUnit.Case, async: false

  alias Laev.{CLI, Holds, Resume}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-tally-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)
    Resume.reload()

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)

      Resume.reload()
    end)

    {:ok, dir: dir}
  end

  defp mark(dir, name, body), do: File.write!(Path.join([dir, "positions", name]), body)

  test "a show with episodes watched is one thing you are in the middle of", %{dir: dir} do
    for e <- 1..3, do: mark(dir, "tv-1399-s1e#{e}", "seen")

    assert CLI.watching_tally().behind == 1
  end

  # The bug this nearly shipped with: held rows were subtracted from "behind" and
  # the caught-up count was the remainder, so putting a show down made it read as
  # caught up.
  test "a held show counts as held, not as caught up", %{dir: dir} do
    for e <- 1..3, do: mark(dir, "tv-1399-s1e#{e}", "seen")
    Holds.hold("tv", 1399)

    tally = CLI.watching_tally()

    assert tally.held == 1
    assert tally.behind == 0
    assert tally.caught_up == 0
  end

  test "a finished show is on neither list", %{dir: dir} do
    for e <- 1..3, do: mark(dir, "tv-1399-s1e#{e}", "seen")
    mark(dir, "tv-1399", "seen")

    tally = CLI.watching_tally()

    assert tally.behind == 0
    assert tally.series_finished == 1
  end

  # What the user asked for: progress is progress, whether or not an episode of it
  # was ever finished.
  test "a film you are half an hour into counts", %{dir: dir} do
    mark(dir, "movie-671", "2135")
    Resume.put("movie", 671, %{"type" => "movie", "tmdb_id" => 671, "title" => "Harry Potter", "updated_at" => 100})

    assert CLI.watching_tally().behind == 1
  end

  test "a film you finished does not", %{dir: dir} do
    mark(dir, "movie-671", "done")
    Resume.put("movie", 671, %{"type" => "movie", "tmdb_id" => 671, "title" => "Harry Potter", "updated_at" => 100})

    assert CLI.watching_tally().behind == 0
  end

  test "nothing watched is nothing to finish" do
    assert CLI.watching_tally() == %{
             behind: 0,
             caught_up: 0,
             held: 0,
             series_finished: 0,
             anime_finished: 0
           }
  end
end
