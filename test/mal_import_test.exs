defmodule Laev.MalImportTest do
  use ExUnit.Case, async: true

  alias Laev.Ratings

  # MAL keeps a count per anime — "24/24 watched" — and laev marks exactly that:
  # episodes of an anime, numbered from one inside it.
  defp entry(fields) do
    Map.merge(
      %{mal_id: 1, title: "x", episodes: nil, episodes_watched: 0, status: "completed", episode_seconds: 1440},
      fields
    )
  end

  defp numbers(marks), do: marks |> Enum.map(& &1.episode) |> Enum.sort()

  test "a finished anime marks every episode, and the anime itself" do
    {episodes, whole} = Ratings.marks_for(entry(%{mal_id: 16_498, episodes: 25, episodes_watched: 25}))

    assert numbers(episodes) == Enum.to_list(1..25)
    assert Enum.all?(episodes, &(&1.mal_id == 16_498))
    assert whole == [%{mal_id: 16_498}]
  end

  test "a part-watched anime marks only as far as it got, and is not finished" do
    {episodes, whole} = Ratings.marks_for(entry(%{episodes: 24, episodes_watched: 7, status: "watching"}))

    assert numbers(episodes) == Enum.to_list(1..7)
    assert whole == [], "seven of twenty-four is not a finished anime"
  end

  # An anime dropped or on hold is still watching that happened; it just never
  # became a finished one.
  test "a dropped anime keeps the episodes it watched" do
    {episodes, whole} = Ratings.marks_for(entry(%{episodes: 12, episodes_watched: 3, status: "dropped"}))

    assert numbers(episodes) == [1, 2, 3]
    assert whole == []
  end

  # A film is one thing of one length. Marking "episode 1" of it as well would
  # count it twice and call it a series.
  test "a one-episode anime is a single mark, not an episode" do
    {episodes, whole} = Ratings.marks_for(entry(%{mal_id: 164, episodes: 1, episodes_watched: 1}))

    assert episodes == []
    assert whole == [%{mal_id: 164}]
  end

  # Nothing about a MAL entry has to be matched to TMDB: no season to land in,
  # no split cour to lay out, nothing that can land on the wrong show.
  test "marks name the MAL entry and nothing else" do
    {episodes, whole} = Ratings.marks_for(entry(%{mal_id: 1425, episodes: 155, episodes_watched: 155}))

    assert length(episodes) == 155
    assert Enum.all?(episodes, &(Map.keys(&1) |> Enum.sort() == [:episode, :mal_id]))
    assert whole == [%{mal_id: 1425}]
  end
end
