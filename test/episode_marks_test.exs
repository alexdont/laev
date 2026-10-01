defmodule Laev.EpisodeMarksTest do
  use ExUnit.Case, async: false

  alias Laev.Position

  # What the lists read to say "3 seasons watched" without asking TMDB anything.
  setup do
    dir = Path.join(System.tmp_dir!(), "laev-marks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp mark(dir, name, body), do: File.write!(Path.join([dir, "positions", name]), body)

  test "episodes group by show and season", %{dir: dir} do
    for e <- 1..3, do: mark(dir, "tv-1399-s1e#{e}", "done")
    mark(dir, "tv-1399-s2e1", "seen")
    mark(dir, "tv-125988-s3e7", "done")

    assert Position.episode_marks() == %{
             {"tv", 1399} => %{1 => 3, 2 => 1},
             {"tv", 125_988} => %{3 => 1}
           }
  end

  test "a part-watched episode is not a watched one", %{dir: dir} do
    mark(dir, "tv-1399-s1e1", "done")
    mark(dir, "tv-1399-s1e2", "900")

    assert Position.episode_marks() == %{{"tv", 1399} => %{1 => 1}}
  end

  test "absolute numbering counts, under season 0", %{dir: dir} do
    # Anime, which laev plays by episode number with no season at all.
    mark(dir, "tv-207468-e1", "done")
    mark(dir, "tv-207468-e2", "done")

    assert Position.episode_marks() == %{{"tv", 207_468} => %{0 => 2}}
  end

  test "films and series marks are not episodes", %{dir: dir} do
    mark(dir, "movie-550", "seen")
    mark(dir, "tv-1399", "seen")

    assert Position.episode_marks() == %{}
  end

  test "nothing marked is an empty map" do
    assert Position.episode_marks() == %{}
  end
end
