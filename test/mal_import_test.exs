defmodule Laev.MalImportTest do
  use ExUnit.Case, async: false

  alias Laev.Ratings

  # MAL counts episodes per entry; TMDB keeps seasons. These are the shapes that
  # disagree, and what the import has to do about each.
  defp entry(fields) do
    Map.merge(%{mal_id: 1, title: "x", episodes: nil, episodes_watched: 0, status: "completed"}, fields)
  end

  defp show(seasons, aired \\ "2020-01-01") do
    %{
      "name" => "Show",
      "seasons" =>
        Enum.map(seasons, fn {number, count} ->
          %{"season_number" => number, "episode_count" => count, "air_date" => aired}
        end)
    }
  end

  defp episodes(marks, season) do
    marks |> Enum.filter(&(&1.season == season)) |> Enum.map(& &1.episode) |> Enum.sort()
  end

  test "a finished season marks every episode of it, and the show itself" do
    mapped = [entry(%{mal_id: 16_498, episodes: 25, episodes_watched: 25})]
    shows = %{1429 => show([{1, 25}])}

    {marks, overflow, series} = Ratings.plan_marks(with_map(mapped, {"tv", 1429, 1}), shows)

    assert episodes(marks, 1) == Enum.to_list(1..25)
    assert overflow == []
    assert series == [%{type: "tv", tmdb_id: 1429, season: nil, episode: nil}]
  end

  test "a part-watched anime marks only as far as it got" do
    mapped = [entry(%{episodes: 24, episodes_watched: 7, status: "watching"})]
    {marks, _over, series} = Ratings.plan_marks(with_map(mapped, {"tv", 55, 1}), %{55 => show([{1, 24}])})

    assert episodes(marks, 1) == Enum.to_list(1..7)
    assert series == [], "seven of twenty-four is not a finished show"
  end

  # Kaijuu No. 8: MAL lists the second cour as its own anime, TMDB keeps both
  # inside season 1. The second cour has to continue into episode 13.
  test "a second cour continues through a season TMDB merged" do
    mapped = [
      entry(%{mal_id: 1, title: "cour 1", episodes: 12, episodes_watched: 12}),
      entry(%{mal_id: 2, title: "cour 2", episodes: 11, episodes_watched: 11})
    ]

    {marks, overflow, series} = Ratings.plan_marks(with_map(mapped, {"tv", 207_468, 1}), %{207_468 => show([{1, 23}])})

    assert episodes(marks, 1) == Enum.to_list(1..23)
    assert overflow == []
    assert series != [], "every episode the show has is watched"
  end

  # The same two entries, against a show TMDB split into two seasons: the second
  # cour belongs to season 2, not to episodes that season 1 doesn't have.
  test "a second cour continues into the next season when TMDB split them" do
    mapped = [
      entry(%{mal_id: 1, title: "s1", episodes: 12, episodes_watched: 12}),
      entry(%{mal_id: 2, title: "s2", episodes: 11, episodes_watched: 11})
    ]

    {marks, overflow, _series} = Ratings.plan_marks(with_map(mapped, {"tv", 99, 1}), %{99 => show([{1, 12}, {2, 11}])})

    assert episodes(marks, 1) == Enum.to_list(1..12)
    assert episodes(marks, 2) == Enum.to_list(1..11)
    assert overflow == []
  end

  # An OVA or a recap film filed under the show's id: it has nowhere to go, and
  # inventing episodes for it would put ticks on episodes that don't exist.
  test "episodes with nowhere to go are reported, not invented" do
    mapped = [
      entry(%{mal_id: 1, title: "the series", episodes: 12, episodes_watched: 12}),
      entry(%{mal_id: 2, title: "the OVA", episodes: 2, episodes_watched: 2})
    ]

    {marks, overflow, _series} = Ratings.plan_marks(with_map(mapped, {"tv", 7, 1}), %{7 => show([{1, 12}])})

    assert episodes(marks, 1) == Enum.to_list(1..12)
    assert overflow == ["the OVA"]
  end

  test "a watched film is one mark" do
    {marks, overflow, series} = Ratings.plan_marks(with_map([entry(%{episodes: 1, episodes_watched: 1})], {"movie", 128}), %{})

    assert marks == [%{type: "movie", tmdb_id: 128, season: nil, episode: nil}]
    assert {overflow, series} == {[], []}
  end

  # A finished season of a five-season anime is a finished season. Only a show
  # that is one season is finished when that season is.
  test "a season of a longer show does not mark the whole show watched" do
    mapped = [entry(%{episodes: 12, episodes_watched: 12})]
    {_marks, _over, series} = Ratings.plan_marks(with_map(mapped, {"tv", 5, 1}), %{5 => show([{1, 12}, {2, 12}])})

    assert series == []
  end

  test "a show TMDB knows nothing about still marks what MAL counted" do
    mapped = [entry(%{episodes: 13, episodes_watched: 13})]
    {marks, overflow, _series} = Ratings.plan_marks(with_map(mapped, {"tv", 404, 3}), %{})

    assert episodes(marks, 3) == Enum.to_list(1..13)
    assert overflow == []
  end

  # plan_marks reads the mapping through AnimeMap, so the test supplies it the
  # same way the map would: one cached file holding exactly these entries.
  defp with_map(entries, target) do
    dir = Path.join(System.tmp_dir!(), "laev-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:laev_app, :data_dir, dir)

    ids =
      Map.new(entries, fn e ->
        {Integer.to_string(e.mal_id),
         case target do
           {"tv", id, season} -> ["tv", id, season]
           {"movie", id} -> ["movie", id]
         end}
      end)

    File.write!(Path.join(dir, "anime-map.json"), Jason.encode!(%{"fetched_at" => System.os_time(:second), "ids" => ids}))
    Laev.AnimeMap.forget()
    on_exit(fn -> File.rm_rf(dir) end)
    entries
  end
end
