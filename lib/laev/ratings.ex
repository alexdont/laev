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

  alias Laev.{Anime, AnimeMap, MAL, Position, Sync, Tmdb}

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
  Mark your MyAnimeList list watched, in MyAnimeList's own terms.

  Anime is not folded into TMDB here. MAL keeps a season as its own entry — "Lupin
  III: Part II" is one anime with 155 episodes — and that is exactly what laev
  marks: `mal-1425-e12`, an episode of an anime, rather than a season of a show
  that happens to contain it. Which means nothing has to be matched to anything:
  the list says 24 of 24 watched, and 24 episode marks is what that is. A
  part-watched anime marks as far as it got; a one-episode anime (a film, an OVA)
  is a single mark, because that is all it is.

  Anime laev already had under TMDB ids is cleared on the way through — the same
  watching, recorded twice in two numbering schemes, would be counted twice.

  Returns `%{marked:, already:, partial:, failed:, finished:, anime:, episodes:,
  hours:, cleared:}`.
  """
  def import_from_mal(report \\ fn _line -> :ok end) do
    if MAL.authenticated?() do
      report.("reading your list from MyAnimeList…")

      with {:ok, entries} <- MAL.list(&report.("  #{&1}")) do
        # Every anime on the list described in one go — title, episode count,
        # episode length — so the stats page and the lists never ask again.
        Anime.put_many(Map.new(entries, &{&1.mal_id, described(&1)}))

        carried = carry_over_to_mal(report)
        cleared = clear_tmdb_anime_marks(report)
        started = Enum.filter(entries, &(&1.episodes_watched > 0))
        {plan, whole} = started |> Enum.map(&marks_for/1) |> unzip_marks()

        episodes = Enum.reduce(plan, @no_marks, &mark/2)
        finished = Enum.reduce(whole, @no_marks, &mark/2)
        counts = Map.merge(episodes, finished, fn _key, a, b -> a + b end)

        if counts.marked > 0 or cleared > 0, do: Sync.live_push()

        Map.merge(counts, %{
          finished: finished.marked,
          anime: length(started),
          episodes: Enum.sum(Enum.map(started, & &1.episodes_watched)),
          hours: div(Enum.sum(Enum.map(started, &((&1.episode_seconds || 0) * &1.episodes_watched))), 3600),
          cleared: cleared,
          carried: carried
        })
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, :not_linked}
    end
  end

  defp described(entry) do
    %{
      title: entry.title,
      episodes: entry.episodes,
      seconds: entry.episode_seconds,
      status: entry.status,
      score: entry.score,
      updated: entry.updated
    }
  end

  @doc """
  The marks one MAL entry stands for: `{episode_marks, whole_anime_mark}`.

  A film is only ever the whole thing. A series gets an episode each, and the
  whole-anime mark as well once the list calls it completed — which is what makes
  it read as finished rather than as a pile of episodes.
  """
  def marks_for(entry) do
    cond do
      entry.episodes == 1 ->
        {[], [%{mal_id: entry.mal_id}]}

      entry.status == "completed" ->
        {episode_marks(entry), [%{mal_id: entry.mal_id}]}

      true ->
        {episode_marks(entry), []}
    end
  end

  defp episode_marks(entry) do
    for n <- 1..entry.episodes_watched//1, do: %{mal_id: entry.mal_id, episode: n}
  end

  defp unzip_marks(pairs) do
    Enum.reduce(pairs, {[], []}, fn {episodes, whole}, {all_episodes, all_whole} ->
      {episodes ++ all_episodes, whole ++ all_whole}
    end)
  end

  @doc """
  Send progress the TMDB side holds, and MyAnimeList doesn't, to the list.

  Anime filed under a TMDB show rather than its MAL entry — laev used to do that
  to every Korean and Chinese animation, whose original language isn't Japanese —
  was tracked in the wrong place, and the marks were about to be cleared as
  stale. Clearing watching is not what they are: they are episodes somebody
  watched, and the list has never heard about them.

  So they go up first. Only when the cross-id list names exactly one anime for
  the show, since several parts means nothing here knows which these episodes
  belonged to, and only when the TMDB side is actually ahead. Returns how many
  anime were pushed.
  """
  def carry_over_to_mal(report \\ fn _line -> :ok end) do
    carried =
      for {{"tv", tmdb_id}, seasons} <- Position.episode_marks(),
          [mal_id] <- [AnimeMap.mal_ids("tv", tmdb_id)],
          watched = seasons |> Map.values() |> Enum.sum(),
          watched > 0,
          ahead?(mal_id, watched),
          do: push_carried(mal_id, watched)

      |> Enum.filter(& &1)

    if carried != [], do: report.("sending #{length(carried)} anime's progress up to MyAnimeList…")
    length(carried)
  end

  defp ahead?(mal_id, watched) do
    case MAL.list_status(mal_id) do
      %{episodes_watched: on_list} -> watched > on_list
      _ -> true
    end
  end

  defp push_carried(mal_id, watched) do
    total = Anime.episodes(mal_id)

    case MAL.set_progress(mal_id, watched, total) do
      {:ok, fields} ->
        Anime.set_status(mal_id, fields.status)
        catch_up(mal_id, fields.num_watched_episodes, fields.status)
        true

      _ ->
        false
    end
  end

  # The one-time move off TMDB keys. Anime used to be marked as seasons of TMDB
  # shows, which meant matching two sites that count anime differently and getting
  # it wrong in the gaps — a row reading a hundred hours opening a series with
  # nothing watched in it. Those marks are removed, not translated: MyAnimeList is
  # the record now, and it is about to supply all of them again.
  #
  # Only marks. A position partway through an episode is somebody's place in
  # something, and keeping it costs nothing.
  defp clear_tmdb_anime_marks(report) do
    dir = Path.join(data_dir(), "positions")

    stale =
      case File.ls(dir) do
        {:ok, names} -> Enum.filter(names, &stale_anime_mark?(dir, &1))
        _ -> []
      end

    if stale != [], do: report.("clearing #{length(stale)} anime marks kept under TMDB ids…")
    Enum.each(stale, &File.rm(Path.join(dir, &1)))
    length(stale)
  end

  defp stale_anime_mark?(dir, name) do
    with {type, id} <- tmdb_key(name),
         true <- AnimeMap.anime?(type, id),
         {:ok, body} <- File.read(Path.join(dir, name)) do
      String.trim(body) in ["done", "seen"]
    else
      _ -> false
    end
  end

  defp tmdb_key(name) do
    cond do
      match = Regex.run(~r/^movie-(\d+)$/, name) -> {"movie", String.to_integer(Enum.at(match, 1))}
      match = Regex.run(~r/^tv-(\d+)/, name) -> {"tv", String.to_integer(Enum.at(match, 1))}
      true -> nil
    end
  end

  defp data_dir do
    Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
  end

  @doc """
  Bring laev's marks up to the episode count MyAnimeList now holds.

  A list keeps a count, not a tick list, so "7 watched" is a claim about seven
  episodes — and laev only played one of them. Watching episode 7 of something
  you had been watching elsewhere would otherwise leave laev saying 1/13 while
  the list says 7/13, and the two would disagree on the page you look at.

  Gaps only. A position partway through an episode is somebody's place in it and
  is never stamped over. `status` finishing the anime marks the anime itself, so
  it leaves the Watchlist the moment the list says it is done.

  Returns how many marks were newly written.
  """
  def catch_up(mal_id, count, status \\ nil) when is_integer(mal_id) do
    written =
      if is_integer(count) and count > 0 do
        Enum.count(1..count//1, fn n ->
          ctx = %{mal_id: mal_id, episode: n}

          case decide(Position.mark_state(ctx)) do
            :mark ->
              Position.set_watched(ctx, true)
              true

            _ ->
              false
          end
        end)
      else
        0
      end

    if status == "completed", do: Position.set_watched(%{mal_id: mal_id}, true)
    written
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
