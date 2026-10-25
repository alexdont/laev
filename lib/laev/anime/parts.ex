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
    ids =
      for mal <- Laev.AnimeMap.mal_ids("tv", tmdb_id),
          {"tv", _id, entry_season} <- [Laev.AnimeMap.tmdb(mal)],
          (entry_season || 1) == season,
          do: mal

    warn_if_muddled(tmdb_id)
    learn_lengths(ids)

    trim(Enum.map(ids, &{&1, Laev.Anime.episodes(&1)}), total, 0, [])
  end

  @doc """
  Are the episode counts of a season's entries all known?

  Worth asking before laying out a long list: `parts/3` will go and find what
  is missing, and a page of a hundred rows should not each trigger that.
  """
  def ready?(tmdb_id, season) do
    lengths =
      for mal <- Laev.AnimeMap.mal_ids("tv", tmdb_id),
          {"tv", _id, entry_season} <- [Laev.AnimeMap.tmdb(mal)],
          (entry_season || 1) == season,
          do: Laev.Anime.episodes(mal)

    Enum.all?(lengths, &is_integer/1)
  end

  # A list that has filed an entry under the wrong show would lay a season out
  # under the wrong anime, and nothing about the result would look wrong — so it
  # says so, once per show per run, rather than answering quietly.
  defp warn_if_muddled(tmdb_id) do
    key = {__MODULE__, :warned, tmdb_id}

    with nil <- :persistent_term.get(key, nil),
         {:suspect, detail} <- Laev.AnimeMap.consistent?("tv", tmdb_id) do
      :persistent_term.put(key, true)
      require Logger
      Logger.warning("laev: cross-id list looks muddled — #{detail}")
    end

    :ok
  rescue
    _ -> :ok
  end

  # How long each entry is, found where it isn't already known.
  #
  # This read only the user's own MyAnimeList list, so the answer depended on
  # whose list was loaded: an account that had never added the first cour got
  # nil for it, `trim/4` dropped it as unknown, and every episode of the season
  # landed on the second cour — episode 7 searched as S02E07. Nothing looked
  # wrong, and it was wrong for everybody but the person who had added it.
  #
  # Bleach is the case to hold in mind: season 2 is four cours of thirteen, and
  # with the third missing, episode 30 located itself in the fourth.
  defp learn_lengths(ids) do
    missing = Enum.reject(ids, &is_integer(Laev.Anime.episodes(&1)))

    for mal <- missing, do: learn_one(mal)

    :ok
  end

  # MyAnimeList first, because it is what the entries are numbered by; Kitsu
  # after, so the answer does not depend on an account being connected at all.
  defp learn_one(mal) do
    with nil <- from_mal(mal), do: from_kitsu(mal)
  end

  defp from_mal(mal) do
    case Laev.Anime.learn(mal) do
      %{episodes: episodes} when is_integer(episodes) -> episodes
      _ -> nil
    end
  end

  defp from_kitsu(mal) do
    with {:ok, kitsu_id} <- Laev.Kitsu.kitsu_id_from_mal(mal),
         episodes when is_integer(episodes) and episodes > 0 <- Laev.Kitsu.episode_count(kitsu_id) do
      # Remembered under the same key MyAnimeList's own answer would use, so it
      # is asked for once however it was found.
      Laev.Anime.put_many(%{mal => %{episodes: episodes}})
      episodes
    else
      _ -> nil
    end
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
