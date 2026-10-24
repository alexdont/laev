defmodule Laev.Anime.Parts do
  @moduledoc """
  Anime is counted two ways, and this reconciles them.

  MyAnimeList lists every cour as its own entry — "Seihantai na Kimi to Boku",
  then "… 2nd Season" — while TMDB keeps one show with seasons, and sometimes
  merges two cours into a single season of 25 rather than 12 + 13. The cross-id
  list ties each MAL entry to a TMDB show and season, so when that happens both
  entries land on the same season, and `Laev.AnimeMap.mal_id/3` keeps only one
  of them: half the episodes of that season would then be searched for, and
  marked, under the wrong anime.

  So the entries sharing a season are laid end to end, oldest first — MAL ids
  grow with time — each taking as many episodes as MAL says it has. Episode 13
  of TMDB's season 1 is then episode 1 of the second entry. A season with one
  entry is exactly what the plain lookup gives, so nothing changes where nothing
  was wrong.
  """

  @doc """
  The MAL entries of a TMDB season, oldest first, each with its episode count
  (or nil when MAL doesn't say): `[{mal_id, episodes}]`.

  The cross-id list also files specials, recaps and OVAs under the season they
  belong to, with no episode count and no episodes on TMDB's side. They are not
  parts of the season: an entry whose length is unknown is skipped unless it is
  the last one, and once `total` — the season's episode count on TMDB — is used
  up, nothing after it is a part. *That Time I Got Reincarnated as a Slime*
  season 1 is one entry of 24 plus two such extras.
  """
  def parts(tmdb_id, season, total \\ nil) do
    all =
      for mal <- Laev.AnimeMap.mal_ids("tv", tmdb_id),
          {"tv", _id, entry_season} <- [Laev.AnimeMap.tmdb(mal)],
          (entry_season || 1) == season,
          do: {mal, Laev.Anime.episodes(mal)}

    trim(all, total, 0, [])
  end

  defp trim([], _total, _offset, acc), do: Enum.reverse(acc)

  defp trim([{_mal, count} = part | rest], total, offset, acc) do
    cond do
      is_integer(total) and total > 0 and offset >= total -> Enum.reverse(acc)
      count == nil and rest != [] -> trim(rest, total, offset, acc)
      true -> trim(rest, total, offset + (count || 0), [part | acc])
    end
  end

  @doc """
  Where an episode of a TMDB season really is: `{mal_id, episode_of_that_entry}`,
  or nil when the season has no MAL entry at all.
  """
  def locate(tmdb_id, season, episode) when is_integer(season) and is_integer(episode) do
    case parts(tmdb_id, season) do
      [] -> nil
      [{mal, _count}] -> {mal, episode}
      parts -> place(parts, episode, 0)
    end
  end

  def locate(_tmdb_id, _season, _episode), do: nil

  # An entry whose length is unknown takes whatever is left; so does the last.
  defp place([{mal, count} | rest], episode, offset) do
    if rest == [] or not is_integer(count) or episode <= offset + count,
      do: {mal, episode - offset},
      else: place(rest, episode, offset + count)
  end

  @doc "The reverse: an episode of a MAL entry, as TMDB's season numbers it."
  def to_tmdb(tmdb_id, season, mal, local) when is_integer(local) do
    offset =
      tmdb_id
      |> parts(season)
      |> Enum.take_while(fn {entry, _count} -> entry != mal end)
      |> Enum.reduce(0, fn {_entry, count}, acc -> acc + (count || 0) end)

    offset + local
  end

  @doc """
  The entry a whole title is rated under: its first season's first entry.

  MyAnimeList rates by entry and TMDB by show, so something has to decide which
  entry "this anime" means.
  """
  def first_entry(tmdb_id) do
    case parts(tmdb_id, 1) do
      [{mal, _count} | _] -> mal
      [] -> List.first(Laev.AnimeMap.mal_ids("tv", tmdb_id))
    end
  end

  @doc """
  How many episodes of a season are watched, added up across its entries —
  which is the only way to count a season two entries share.
  """
  def watched_in_season(tmdb_id, season, marks, total \\ nil) do
    tmdb_id
    |> parts(season, total)
    |> Enum.reduce(0, fn {mal, _count}, acc -> acc + Map.get(marks, mal, 0) end)
  end
end
