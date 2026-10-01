defmodule Laev.Ratings do
  @moduledoc """
  Your TMDB ratings, read back as "I have watched this".

  A rating is the one unambiguous record of having seen something — nobody
  scores a film they haven't watched — and a TMDB account can hold years of them,
  imported from IMDb. Reading them in is what makes the rest of laev tell the
  truth about a library it never played: titles grey out in search and Featured,
  and the stats stop pretending a decade of watching began when laev was
  installed.

  Marks only. No resume points, no history entries, no sources: laev didn't play
  these, and the stats keep them in the off-laev bucket where an assumed runtime
  belongs.
  """

  alias Laev.{AnimeMap, MAL, Position, Seasons, Sync, Tmdb}

  @no_marks %{marked: 0, already: 0, partial: 0, failed: 0}

  @doc """
  Mark everything you have rated on TMDB as watched.

  Returns `%{marked:, already:, partial:, failed:}`. Idempotent — a second run
  marks nothing, because everything is already marked.

  `report` is called with progress lines so a long import can speak for itself.
  """
  def import_from_tmdb(report \\ fn _line -> :ok end) do
    if Tmdb.account?() do
      report.("reading your ratings from TMDB…")

      films = Tmdb.rated("movies", &report.("  #{&1} films…"))
      shows = Tmdb.rated("tv", &report.("  #{&1} shows…"))
      episodes = Tmdb.rated("tv/episodes", &report.("  #{&1} episodes…"))

      # The names ride along in the same response, so the stats page has something
      # readable for a title it has never played — otherwise a thousand imported
      # rows read as "tv #4607", which says nothing about what you watched.
      remember_names(films, shows)

      counts =
        [
          Enum.map(films, &ctx_for_movie/1),
          Enum.map(shows, &ctx_for_show/1),
          Enum.map(episodes, &ctx_for_episode/1)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(@no_marks, &mark/2)

      if counts.marked > 0, do: Sync.live_push()
      counts
    else
      {:error, :no_session}
    end
  end


  @doc """
  Mark everything on your MyAnimeList list as watched, episode by episode.

  MAL keeps a count rather than a tick list — "24/24 watched" — so the count is
  laid out over the matching TMDB season: 24 watched becomes episodes 1 to 24 of
  the season the cross-id list pins that MAL entry to. A part-watched anime
  marks only as far as it got, so a show you are seven episodes into reads as
  seven episodes here too, not as finished.

  Split cours are the awkward case: MAL lists "Kaijuu No. 8" and "Kaijuu No. 8
  2nd Season" separately while TMDB may hold both inside one season. Entries
  landing on the same season are laid end to end in MAL id order — the first
  cour's episodes, then the second's — and anything that runs past the end of
  the season TMDB actually has is left unmarked and reported, rather than
  stamping marks onto episodes that don't exist.

  Returns `%{marked:, already:, partial:, failed:, series:, anime:, episodes:,
  hours:, unmapped: [title], overflow: [title]}`.
  """
  def import_from_mal(report \\ fn _line -> :ok end) do
    if MAL.authenticated?() do
      with {:ok, _ids} <- AnimeMap.ensure(report),
           report.("reading your list from MyAnimeList…"),
           {:ok, entries} <- MAL.list(&report.("  #{&1}")) do
        started = Enum.filter(entries, &(&1.episodes_watched > 0))
        {mapped, unmapped} = Enum.split_with(started, &(AnimeMap.tmdb(&1.mal_id) != nil))
        shows = show_details(mapped, report)
        {plan, overflow, series} = plan_marks(mapped, shows)

        remember_anime_names(mapped, shows)
        remember_season_counts(shows)

        # Counted apart so the summary can say "4,000 episodes and 109 anime"
        # and still be right on a second run, where the episodes are new and the
        # series marks already there.
        episodes = Enum.reduce(plan, @no_marks, &mark/2)
        whole = Enum.reduce(series, @no_marks, &mark/2)
        counts = Map.merge(episodes, whole, fn _key, a, b -> a + b end)

        if counts.marked > 0, do: Sync.live_push()

        Map.merge(counts, %{
          series: whole.marked,
          anime: length(started),
          episodes: Enum.sum(Enum.map(started, & &1.episodes_watched)),
          hours: div(Enum.sum(Enum.map(started, &((&1.episode_seconds || 0) * &1.episodes_watched))), 3600),
          unmapped: Enum.map(unmapped, & &1.title),
          overflow: overflow
        })
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, :not_linked}
    end
  end

  # One TMDB lookup per show, not per MAL entry — a five-season anime is five
  # entries on MAL and one show here. Gives the season episode counts the layout
  # needs, and the names the stats page shows.
  defp show_details(mapped, report) do
    ids =
      mapped
      |> Enum.flat_map(fn entry ->
        case AnimeMap.tmdb(entry.mal_id) do
          {"tv", id, _season} -> [id]
          _ -> []
        end
      end)
      |> Enum.uniq()

    if ids != [], do: report.("matching #{length(ids)} shows against TMDB…")

    ids
    |> Task.async_stream(&{&1, Tmdb.tv(&1)}, max_concurrency: 8, timeout: 20_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {id, {:ok, details}}} -> [{id, details}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc """
  Where each MAL entry's episodes land: `{marks, overflow, series_marks}`.

  Separated out because this is the only part of the import with an opinion —
  everything else is a request or a file write. `shows` is `%{tmdb_id =>
  TMDB show details}`, which is what tells the layout how long each season is.
  """
  def plan_marks(mapped, shows) do
    {films, episodes} =
      mapped
      |> Enum.flat_map(fn entry ->
        case AnimeMap.tmdb(entry.mal_id) do
          {"movie", id} -> [{:film, id, entry}]
          {"tv", id, season} -> [{:tv, {id, season}, entry}]
          _ -> []
        end
      end)
      |> Enum.split_with(&(elem(&1, 0) == :film))

    film_marks = for {:film, id, _entry} <- films, do: %{type: "movie", tmdb_id: id, season: nil, episode: nil}

    {episode_marks, overflow, series} =
      episodes
      |> Enum.group_by(fn {_kind, key, _entry} -> key end, fn {_kind, _key, entry} -> entry end)
      |> Enum.reduce({[], [], []}, fn {{id, season}, group}, {marks, over, series} ->
        {new_marks, new_over, finished?} = lay_out(id, season, group, shows[id])

        series =
          if finished? and sole_season?(shows[id], season),
            do: [%{type: "tv", tmdb_id: id, season: nil, episode: nil} | series],
            else: series

        {new_marks ++ marks, new_over ++ over, series}
      end)

    {film_marks ++ episode_marks, overflow, series}
  end

  # Lay a season's MAL entries along the show's own run of episodes, starting at
  # the season the cross-id list points at. Each entry takes as many slots as it
  # has episodes and marks the ones it watched, so the second cour continues
  # where the first stopped — into episode 13 of a 24-episode season when TMDB
  # merged them, or into season 2 episode 1 when it didn't. Returns the marks,
  # the titles that ran off the end of the show, and whether everything the show
  # has is now marked.
  defp lay_out(id, season, group, details) do
    slots = slots_from(details, season, group)

    {marks, over, _offset} =
      group
      |> Enum.sort_by(& &1.mal_id)
      |> Enum.reduce({[], [], 0}, fn entry, {marks, over, offset} ->
        span = Enum.slice(slots, offset, entry.episodes_watched)

        over = if length(span) < entry.episodes_watched, do: [entry.title | over], else: over
        new = for {s, n} <- span, do: %{type: "tv", tmdb_id: id, season: s, episode: n}
        claimed = max(entry.episodes || 0, entry.episodes_watched)

        {new ++ marks, over, offset + claimed}
      end)

    # Finished means every episode the show has is marked — not that the entries
    # ran the length of it. An anime seven episodes into a twenty-four episode
    # season has consumed the season and watched a third of it.
    {marks, over, slots != [] and length(marks) >= length(slots)}
  end

  # Every {season, episode} the show has from this season on. A show TMDB knows
  # nothing about falls back to the one season asked for, long enough to hold
  # what MAL claims — better to mark by MAL's count than to mark nothing.
  defp slots_from(details, season, group) do
    case season_line(details, season) do
      [] ->
        want = Enum.sum(Enum.map(group, &max(&1.episodes || 0, &1.episodes_watched)))
        for n <- 1..max(want, 1)//1, do: {season, n}

      line ->
        for {number, count} <- Enum.sort(line), n <- 1..count//1, do: {number, n}
    end
  end

  defp season_line(details, from) when is_map(details) do
    for %{"season_number" => n, "episode_count" => count} <- details["seasons"] || [],
        is_integer(n) and n >= from,
        is_integer(count) and count > 0,
        do: {n, count}
  end

  defp season_line(_details, _from), do: []

  # "I have seen this show" is only honest when the show is this one season. A
  # finished season of a five-season anime is a finished season; the shelf works
  # that out from the episode marks on its own.
  defp sole_season?(details, season) when is_map(details) do
    case aired_seasons(details) do
      [only] -> only == season
      _ -> false
    end
  end

  defp sole_season?(_details, _season), do: false

  defp aired_seasons(%{"seasons" => seasons}) when is_list(seasons) do
    today = Date.utc_today() |> Date.to_iso8601()

    for %{"season_number" => n} = s <- seasons,
        is_integer(n) and n > 0,
        s["air_date"] not in [nil, ""],
        s["air_date"] <= today,
        do: n
  end

  defp aired_seasons(_details), do: []

  # The import is the one place that knows every anime show's shape at once, so
  # it leaves behind what the home screen can't fetch for itself: how many
  # seasons aired, and how long each one is.
  defp remember_season_counts(shows) do
    Enum.each(shows, fn {id, details} ->
      Enum.each(details["seasons"] || [], fn season ->
        with n when is_integer(n) and n > 0 <- season["season_number"],
             count when is_integer(count) and count > 0 <- season["episode_count"] do
          Seasons.put(id, n, count)
        end
      end)
    end)

    shows
    |> Map.new(fn {id, details} -> {id, length(aired_seasons(details))} end)
    |> Seasons.put_aired_seasons_many()
  end

  # TMDB's name where there is one, MAL's otherwise — a stats page reading
  # "tv #216074" says nothing about an evening spent watching it.
  defp remember_anime_names(mapped, shows) do
    names =
      for entry <- mapped, into: %{} do
        case AnimeMap.tmdb(entry.mal_id) do
          {"tv", id, _season} -> {{"tv", id}, shows[id]["name"] || entry.title}
          {"movie", id} -> {{"movie", id}, entry.title}
          _ -> {nil, nil}
        end
      end

    names
    |> Map.reject(fn {key, name} -> is_nil(key) or not is_binary(name) end)
    |> Laev.Titles.put()
  end

  @doc """
  What to do with one rated title, given what laev already knows about it.

  The only interesting case is the middle one: a part-watched position is
  somebody's place in something, and an import must not stamp over it with
  "finished" on the strength of a rating that might predate the rewatch.
  """
  def decide(:none), do: :mark
  def decide(:watched), do: :already
  def decide({:partial, _seconds}), do: :partial

  defp mark(ctx, counts) do
    case decide(Position.mark_state(ctx)) do
      :mark ->
        Position.set_watched(ctx, true)
        if Position.mark_state(ctx) == :watched,
          do: %{counts | marked: counts.marked + 1},
          else: %{counts | failed: counts.failed + 1}

      :already ->
        %{counts | already: counts.already + 1}

      :partial ->
        %{counts | partial: counts.partial + 1}
    end
  end

  defp remember_names(films, shows) do
    names =
      Map.merge(
        for(%{"id" => id, "title" => title} <- films, into: %{}, do: {{"movie", id}, title}),
        for(%{"id" => id, "name" => name} <- shows, into: %{}, do: {{"tv", id}, name})
      )

    Laev.Titles.put(names)
  end

  defp ctx_for_movie(%{"id" => id}) when is_integer(id),
    do: %{type: "movie", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_movie(_rated), do: nil

  # A rated series is a watched series, at title level — the same mark ctrl-w
  # writes, so the ✓ and the greying agree with it.
  defp ctx_for_show(%{"id" => id}) when is_integer(id),
    do: %{type: "tv", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_show(_rated), do: nil

  defp ctx_for_episode(%{"show_id" => show, "season_number" => season, "episode_number" => episode})
       when is_integer(show) and is_integer(season) and is_integer(episode),
       do: %{type: "tv", tmdb_id: show, season: season, episode: episode}

  defp ctx_for_episode(_rated), do: nil
end
