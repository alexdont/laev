defmodule Laev.SeasonCursorTest do
  use ExUnit.Case, async: false

  alias Laev.{CLI, Position, Seasons}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-cursor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    :ok
  end

  defp seasons(counts) do
    counts |> Enum.with_index(1) |> Enum.map(fn {count, n} -> %{"season_number" => n, "episode_count" => count} end)
  end

  defp watch(id, season, episodes) do
    for e <- episodes, do: Position.set_watched(%{type: "tv", tmdb_id: id, season: season, episode: e}, true)
    Seasons.put(id, season, length(Enum.to_list(episodes)) |> max(episodes |> Enum.max(fn -> 0 end)))
  end

  # Three seasons behind you means the fourth is the one you came for.
  test "the cursor opens on the first season not watched through" do
    watch(9, 1, 1..3)
    watch(9, 2, 1..5)
    Seasons.put(9, 1, 3)
    Seasons.put(9, 2, 5)

    assert CLI.first_unwatched_season(9, seasons([3, 5, 8, 8])) == 2
  end

  # A season you are partway into is the season to continue, not to skip.
  test "a partial season keeps the cursor" do
    watch(9, 1, 1..3)
    Seasons.put(9, 1, 3)
    watch(9, 2, 1..2)
    Seasons.put(9, 2, 5)

    assert CLI.first_unwatched_season(9, seasons([3, 5, 8])) == 1
  end

  test "nothing watched starts at the top" do
    assert CLI.first_unwatched_season(9, seasons([3, 5])) == 0
  end

  # With everything behind you, the last season is the one to be standing in.
  test "everything watched lands on the last season" do
    watch(9, 1, 1..3)
    Seasons.put(9, 1, 3)
    watch(9, 2, 1..5)
    Seasons.put(9, 2, 5)

    assert CLI.first_unwatched_season(9, seasons([3, 5])) == 1
  end
end
