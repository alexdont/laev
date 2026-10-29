defmodule Laev.Ratings do
  @moduledoc """
  Your TMDB ratings, read back as "I have watched this".

  Two imports, because TMDB knows *what* and IMDb knows *when*: TMDB's rated
  endpoints carry no rating date, so `import_from_tmdb/1` can only say that
  something was watched, while an IMDb ratings export has a day per title and
  `import_imdb_csv/2` uses it. A date claimed that way is kept apart from one
  laev measured itself — see `Laev.Position.set_watched_on/2`.

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

  # 10 down to 1, which is the order a rating list is read in.
  @score_words [
    {10, "masterpiece"},
    {9, "banger"},
    {8, "really good"},
    {7, "pretty decent"},
    {6, "it's alright"},
    {5, "passable"},
    {4, "not good"},
    {3, "truly bad"},
    {2, "garbage"},
    {1, "absolute trash"}
  ]


  alias Laev.{Anime, AnimeMap, MAL, Position, Sync, Tmdb}

  @no_marks %{marked: 0, already: 0, partial: 0, failed: 0, dated: 0, unresolved: 0, skipped: 0}

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
    Laev.Scope.dir()
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

  @doc """
  Import an IMDb ratings export, dating each title by the day it was rated.

  Give it the CSV or a path to it. Everything rated on IMDb is marked watched —
  the same reading as the TMDB import, since nobody scores a film they have not
  seen — but with the date the export carries rather than the moment of the
  import. A decade of ratings then sits on the ten years it happened over
  instead of all landing today.

  What it does not do: episode rows. An IMDb export lists rated *episodes* by
  their own ids, and resolving two hundred of those to a season and number is a
  separate job with its own failure modes; the show they belong to is marked and
  dated instead, which is the answer to "when did I watch this" at the
  resolution the export is useful for. They are counted as `skipped` so the
  number is visible rather than quietly missing.

  Nothing already known from a real play is overwritten, and a part-watched
  title is left alone exactly as the TMDB import leaves it.

  Returns `%{marked:, already:, partial:, failed:, dated:, skipped:,
  unresolved:}`.
  """
  def import_imdb_csv(csv_or_path, report \\ fn _line -> :ok end) do
    with {:ok, text} <- read_export(csv_or_path) do
      rows = eligible(Laev.Csv.maps(text))
      report.("#{length(rows)} rated titles in the export…")

      resolved =
        rows
        |> Laev.Scope.async_stream(&resolve_row/1, max_concurrency: 8, timeout: 30_000, on_timeout: :kill_task)
        |> Enum.map(fn
          {:ok, result} -> result
          _ -> {:error, :timeout}
        end)

      found = for {:ok, ctx, at, title} <- resolved, do: {ctx, at, title}
      report.("#{length(found)} matched on TMDB, #{length(resolved) - length(found)} not found…")

      counts = Enum.reduce(found, %{@no_marks | dated: 0, unresolved: 0}, &mark_dated/2)
      counts = %{counts | unresolved: length(resolved) - length(found), skipped: skipped_episodes(text)}

      if counts.marked > 0 or counts.dated > 0, do: Sync.live_push()
      counts
    end
  end

  defp read_export(text) when is_binary(text) do
    cond do
      String.contains?(text, "Date Rated") -> {:ok, text}
      File.regular?(text) -> File.read(text)
      true -> {:error, :not_an_imdb_export}
    end
  end

  defp read_export(_other), do: {:error, :not_an_imdb_export}

  # Rated titles with a date. Episode rows are left for the show they belong to.
  defp eligible(rows) do
    rows
    |> Enum.filter(fn row ->
      String.starts_with?(row["Const"] || "", "tt") and
        match?({:ok, _}, Date.from_iso8601(row["Date Rated"] || "")) and
        row["Title Type"] != "TV Episode"
    end)
    |> Enum.uniq_by(& &1["Const"])
  end

  defp skipped_episodes(text) do
    Laev.Csv.maps(text) |> Enum.count(&(&1["Title Type"] == "TV Episode"))
  end

  defp resolve_row(row) do
    with {:ok, date} <- Date.from_iso8601(row["Date Rated"]),
         {:ok, found} <- Tmdb.find_imdb(row["Const"]),
         ctx when is_map(ctx) <- ctx_for_found(found) do
      {:ok, ctx, noon(date), found[:title] || row["Title"]}
    else
      _ -> {:error, row["Const"]}
    end
  end

  defp ctx_for_found(%{type: "movie", id: id}) when is_integer(id),
    do: %{type: "movie", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_found(%{type: "tv", id: id}) when is_integer(id),
    do: %{type: "tv", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_found(_found), do: nil

  # Midday rather than midnight: the export gives a day and nothing finer, and
  # midday is the hour least likely to fall on the wrong side of a timezone
  # when somebody reads it back.
  defp noon(%Date{} = date) do
    {:ok, moment} = DateTime.new(date, ~T[12:00:00], "Etc/UTC")
    DateTime.to_unix(moment)
  end

  defp mark_dated({ctx, at, title}, counts) do
    counts = mark(ctx, counts)

    # The date is written whether or not this run was the one that marked it:
    # a title the TMDB import already marked is exactly what wants a date.
    if Position.mark_state(ctx) == :watched and is_nil(Position.watched_on(ctx)) do
      Position.set_watched_on(ctx, at)
      remember_name(ctx, title)
      %{counts | dated: counts.dated + 1}
    else
      counts
    end
  end

  defp remember_name(%{type: type, tmdb_id: id}, title) when is_binary(title) and title != "",
    do: Laev.Titles.put(%{{type, id} => title})

  defp remember_name(_ctx, _title), do: :ok

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

  @doc """
  The ten words laev rates with, highest first: `[{10, "masterpiece"}, …]`.

  Public because a second interface needs the same words, and the alternative
  is the same list written twice in two languages, drifting apart the first
  time one of them is edited.
  """
  def score_words, do: @score_words

  @doc """
  The word for a score: `score_word(8)` → `"really good"`.

  Takes integers and floats alike — a slider sends 7.5 and a stored rating
  sends 7, and calling Float.round on the integer is a crash, which is how
  this was found. Rounds to the nearest whole score and clamps to 1..10, so
  there is always a word.
  """
  def score_word(score) when is_number(score) do
    whole = score |> round() |> max(1) |> min(10)
    {_score, word} = Enum.find(@score_words, fn {n, _word} -> n == whole end)
    word
  end

  def score_word(_score), do: nil
end
