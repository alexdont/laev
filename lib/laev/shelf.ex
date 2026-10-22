defmodule Laev.Shelf do
  @moduledoc """
  What you are in the middle of, as data.

  The Watchlist is the one screen assembled from everything laev records at
  once — episode marks, your MyAnimeList list, its own history, holds, the TMDB
  cards behind the rows — and reading those together is the fiddly part: what
  counts as caught up, when a show has been quiet long enough to call finished,
  which anime you put down rather than merely left off.

  None of that is display. It lived in the CLI because the CLI was the only
  thing asking, and it answers in rows and counts rather than in anything
  printed — so it lives here, where a second interface can ask the same
  question and get the same answer. Two of them disagreeing about what you are
  watching is the bug this arrangement exists to make impossible, and it is not
  hypothetical: the count already read 28 in one place and 51 in another once.
  """

  alias Laev.{SessionCache, Tmdb}

  # Shows there is actually something to watch of. Caught up is not a thing to
  # do, so it has no business in a number that says how much is left — read from
  # what the page wrote down last time it looked, since the home screen fetches
  # nothing. A show laev has never looked at counts as behind: better to offer it
  # and find out than to hide it on a guess.
  # The directory-wide pass of the same promotion, with the typical runtimes the
  # stats already keep — once per session, before anything counts. Conservative:
  # a title with no cached runtime waits for its episode list to reconcile it
  # against the real one.
  defp promote_finished_positions do
    SessionCache.fetch(:promoted_positions, 86_400, fn ->
      runtimes = Laev.Stats.known_runtimes()
      anime = anime_list()

      Laev.Position.promote_watched(fn name ->
        cond do
          match = Regex.run(~r/^movie-(\d+)$/, name) ->
            as_seconds(runtimes["movie-#{Enum.at(match, 1)}"])

          match = Regex.run(~r/^tv-(\d+)-/, name) ->
            as_seconds(runtimes["tv-#{Enum.at(match, 1)}"])

          match = Regex.run(~r/^mal-(\d+)-e/, name) ->
            anime[String.to_integer(Enum.at(match, 1))][:seconds]

          true ->
            nil
        end
      end)
    end)
  end

  defp as_seconds(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp as_seconds(_other), do: nil

  @doc false
  # Every number the home row and the stats line quote, counted once and grouped
  # exactly the way the page groups its rows. Two screens disagreeing about the
  # same word is worse than either of them being a little off — and they did
  # disagree, the moment the page started counting things the counts didn't.
  def tally do
    promote_finished_positions()
    shows = unfinished_shows()
    anime = unfinished_anime()
    loose = unfinished_resumes(shows, anime)
    held = Laev.Holds.set()

    {held_shows, rest} = Enum.split_with(shows, fn {{type, id}, _marks} -> MapSet.member?(held, {type, id}) end)
    {caught_up, behind_shows} = Enum.split_with(rest, fn {{_type, id}, marks} -> caught_up_by_cache?(id, marks) end)
    {held_anime, behind_anime} = Enum.split_with(anime, fn {_id, entry} -> entry && entry.status == "on_hold" end)
    {held_loose, behind_loose} = Enum.split_with(loose, &Laev.Holds.held?(&1["type"], &1["tmdb_id"]))

    %{
      behind: length(behind_shows) + length(behind_anime) + length(behind_loose),
      caught_up: length(caught_up),
      held: length(held_shows) + length(held_anime) + length(held_loose),
      series_finished: Enum.count(series_marks()),
      anime_finished: length(anime_finished())
    }
  end

  defp caught_up_by_cache?(id, marks) do
    case Laev.Seasons.aired_seasons(id) do
      aired when is_integer(aired) and aired > 0 ->
        Enum.count(marks, fn {season, marked} -> complete_season?(id, season, marked) end) >= aired

      _ ->
        false
    end
  end

  # Episode marks, minus anything already called finished. A show you watched two
  # seasons of sits here until the rest of it is watched or marked — which is the
  # point: it is the list of what you left in the middle.
  def unfinished_shows do
    marks_by_show()
    |> Enum.reject(fn {{type, id}, _seasons} ->
      Laev.Position.finished?(%{type: type, tmdb_id: id, season: nil, episode: nil})
    end)
    |> Enum.sort_by(fn {{type, id}, seasons} ->
      # Most recently watched first, then whatever you have most of.
      recency =
        case Laev.Resume.get(type, id) do
          %{"updated_at" => at} when is_integer(at) -> -at
          _ -> 0
        end

      {recency, -(seasons |> Map.values() |> Enum.sum())}
    end)
  end

  @doc """
  Every row of the Watchlist page, in the order it shows them — shows you are
  partway through, then anime, then whatever you are merely caught up on, with
  the divider between.

  Separated from the screen that draws it so the page can be checked without a
  terminal: this is the part with the fetching, the ordering and the rules in it.
  """
  def rows(report \\ fn _line -> :ok end) do
    shows = unfinished_shows()
    anime = unfinished_anime()
    loose = unfinished_resumes(shows, anime)
    marks = anime_marks()

    if shows == [] and anime == [] and loose == [] do
      []
    else
      cards = load_cards(card_keys(shows, anime, loose), report)

      # Anime ordered after the shows, and ordered among themselves already — the
      # index continues across both so one sort keeps the whole page in order.
      anime_rows =
        anime
        |> Enum.with_index(length(shows))
        |> gather(fn {{mal_id, entry}, order} ->
          unfinished_anime_title({mal_id, entry}, Map.get(marks, mal_id, 0), order, cards)
        end)

      loose_rows =
        loose
        |> Enum.with_index(length(shows) + length(anime))
        |> gather(fn {entry, order} -> unfinished_resume_title(entry, order, cards) end)

      shows
      |> Enum.with_index()
      |> gather(fn {{{type, id}, seasons}, order} -> unfinished_title(type, id, seasons, order, cards) end)
      |> Enum.concat(anime_rows)
      |> Enum.concat(loose_rows)
      |> remember_aired_seasons()
      |> divide_sections()
    end
  end

  # Every TMDB title the page is about to draw.
  defp card_keys(shows, anime, loose) do
    show_keys = Enum.map(shows, fn {{type, id}, _marks} -> {type, id} end)
    loose_keys = Enum.map(loose, &{&1["type"], &1["tmdb_id"]})

    anime_keys =
      Enum.flat_map(anime, fn {mal_id, _entry} ->
        case Laev.AnimeMap.tmdb(mal_id) do
          {type, id, _season} -> [{type, id}]
          {type, id} -> [{type, id}]
          _ -> []
        end
      end)

    Enum.uniq(show_keys ++ anime_keys ++ loose_keys)
  end

  # What the page draws itself from. Cards it already has are free; one it has
  # never seen costs a request, once. A week-old card is refreshed behind the
  # list rather than in front of it — the page is on screen by then, and a
  # creeping vote average is not worth a second of waiting for.
  def load_cards(keys, report) do
    known = Laev.Cards.get_many(keys)
    missing = Enum.reject(keys, &Map.has_key?(known, &1))

    if missing != [], do: report.("reading #{length(missing)} titles from TMDB — once each…")

    fetched =
      missing
      |> Laev.Scope.async_stream(&{&1, fetch_card(&1)}, max_concurrency: 8, timeout: 20_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, {key, details}} when is_map(details) -> [{key, details}]
        _ -> []
      end)
      |> Map.new()

    Laev.Cards.put_many(fetched)
    refresh_cards_later(keys -- missing)

    Map.merge(known, fetched)
  end

  defp fetch_card({type, id}) do
    case details(type, id) do
      {:ok, details} -> details
      _ -> nil
    end
  end

  defp refresh_cards_later(keys) do
    case Laev.Cards.stale(keys) do
      [] ->
        :ok

      stale ->
        Laev.Scope.spawn(fn ->
          stale
          |> Laev.Scope.async_stream(&{&1, fetch_card(&1)}, max_concurrency: 4, timeout: 20_000, on_timeout: :kill_task)
          |> Enum.flat_map(fn
            {:ok, {key, details}} when is_map(details) -> [{key, details}]
            _ -> []
          end)
          |> Map.new()
          |> Laev.Cards.put_many()
        end)
    end
  end

  # Build rows in parallel, keeping the ones that came back: a title TMDB could
  # not be reached for is a row missing, not a page that fails.
  defp gather(items, build) do
    items
    |> Laev.Scope.async_stream(build, max_concurrency: 8, timeout: 20_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, row} when is_map(row) -> [row]
      _ -> []
    end)
  end

  # The same shape every other title list uses, so enter plays it and ctrl-w,
  # ctrl-s and ctrl-o all work here too. Falls back to the remembered name when
  # TMDB can't be reached, rather than dropping the row.
  defp unfinished_title(type, id, seasons, order, cards) do
    case Map.fetch(cards, {type, id}) do
      {:ok, details} ->
        # A show watched through that has aired nothing for five years marks
        # itself and leaves — at that point it is over by any reading, and the
        # row would just sit here. Anything newer waits in caught up, marked
        # only by your ctrl-w: a 2025 show between seasons is not finished,
        # whatever TMDB's status says about it.
        if concluded?(details) and seasons_complete?(details, seasons) do
          Laev.Position.set_watched(%{type: "tv", tmdb_id: id, season: nil, episode: nil}, true)
          Laev.Sync.live_push()
          nil
        else
          details
          |> unfinished_row(type, id)
          |> Map.merge(season_progress_note(details, seasons))
          |> hold_note()
          |> Map.put(:order, order)
        end

      _ ->
        %{
          id: id,
          type: type,
          title: Laev.Titles.get(type, id) || "#{type} ##{id}",
          year: nil,
          poster: nil,
          overview: nil,
          vote: nil,
          popularity: nil,
          held: Laev.Holds.held?(type, id),
          watched_at: last_watched_at(type, id),
          order: order
        }
    end
  end

  defp last_watched_at(type, id) do
    case Laev.Resume.get(type, id) do
      %{"updated_at" => at} when is_integer(at) -> at
      _ -> 0
    end
  end

  # "Probably obviously done": nothing has aired for five years. A newer show
  # between seasons is not finished — marking it would let you forget it, and
  # revivals routinely take three or four — so it waits in caught up however
  # certain its ending looks. TMDB's status is deliberately not consulted: it
  # files K-dramas as Ended in week one and keeps dead shows Returning for a
  # decade; silence is the honest signal.
  @concluded_after_days 5 * 365

  def concluded?(%{"last_air_date" => date}) when is_binary(date) and date != "" do
    case Date.from_iso8601(date) do
      {:ok, last} -> Date.diff(Date.utc_today(), last) > @concluded_after_days
      _ -> false
    end
  end

  def concluded?(_details), do: false

  # Every aired season watched through — what "complete" means for a show.
  @doc "Every aired season watched through — what complete means for a show."
  def seasons_complete?(details, marks) do
    real = Enum.filter(details["seasons"] || [], &(&1["season_number"] > 0))

    real != [] and
      Enum.all?(real, fn season ->
        number = season["season_number"]
        total = Laev.Seasons.aired(details["id"], number) || season["episode_count"] || 0

        total > 0 and Map.get(marks, number, 0) >= total
      end)
  end

  # Said on the row as well as over the section, so typing "hold" in the filter
  # finds everything you put down, shows and anime alike.
  defp hold_note(%{held: true} = row), do: Map.put(row, :note, " · on hold" <> (row[:note] || ""))

  defp hold_note(row), do: row

  # Anime you have episodes of and have not finished — which is the page's whole
  # job, and anime was missing from it because the page counts TMDB shows and
  # anime is counted by MyAnimeList entry. The status comes from the list, so a
  # dropped anime stays dropped and out of the way.
  defp unfinished_anime do
    marks = anime_marks()
    finished = MapSet.new(anime_finished())
    described = anime_list()

    # Every anime laev has any record of being in the middle of — the marks it
    # wrote, and its own history for one your list has never heard of. Driving
    # this from the list alone is what hid an anime you are seven episodes into
    # here because you had never added it there.
    (Map.keys(marks) ++ resume_anime_ids())
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(finished, &1))
    |> Enum.reject(&(described[&1][:status] == "dropped"))
    |> Enum.map(&{&1, described[&1]})
    |> Enum.sort_by(fn {mal_id, anime} ->
      # Watching first: that is the half of this list with something to do tonight.
      {if(anime && anime.status == "watching", do: 0, else: 1), -Map.get(marks, mal_id, 0)}
    end)
  end

  # Anime laev has a position in: the id comes from the history entry when it was
  # played recently enough to carry one, and from the cross-id list otherwise —
  # offline either way, and only when that list names exactly one anime for the
  # show, since several parts means nothing here knows which you were watching.
  defp resume_anime_ids do
    for entry <- Laev.Resume.all(), not title_finished?(entry), id <- anime_ids_for(entry), do: id
  end

  defp anime_ids_for(%{"mal_id" => mal_id}) when is_integer(mal_id), do: [mal_id]

  defp anime_ids_for(entry) do
    case Laev.AnimeMap.mal_ids(entry["type"], entry["tmdb_id"]) do
      [only] -> [only]
      _ -> []
    end
  end

  defp title_finished?(entry) do
    Laev.Position.finished?(%{type: entry["type"], tmdb_id: entry["tmdb_id"], season: nil, episode: nil})
  end

  # Started, with nothing finished yet: an hour into a film, five minutes into an
  # episode. Being in the middle of something doesn't wait for a whole episode to
  # go by, and these were the rows missing from the page entirely — laev had the
  # position, and nothing asked it.
  defp unfinished_resumes(shows, anime) do
    covered_shows = MapSet.new(shows, fn {{type, id}, _seasons} -> {type, id} end)
    covered_anime = MapSet.new(anime, fn {mal_id, _described} -> mal_id end)

    Enum.filter(Laev.Resume.all(), fn entry ->
      not title_finished?(entry) and
        not MapSet.member?(covered_shows, {entry["type"], entry["tmdb_id"]}) and
        not Enum.any?(anime_ids_for(entry), &MapSet.member?(covered_anime, &1)) and
        Laev.Position.resume_at(resume_ctx(entry)) != nil
    end)
  end

  # The row says where you are from the history, like every other title row does,
  # so there is nothing extra to write on it.
  defp unfinished_resume_title(entry, order, cards) do
    type = entry["type"]
    id = entry["tmdb_id"]

    Map.get(cards, {type, id}, %{})
    |> unfinished_row(type, id)
    |> hold_note()
    |> Map.put(:order, order)
  end

  # One row, in the same shape as every other title row so enter plays it. The
  # title is the MAL entry's own name, which is also what matches it on Kitsu
  # when you open it — "Lupin III: Part 5", rather than seven seasons of "Lupin
  # the 3rd" to choose between.
  defp unfinished_anime_title({mal_id, nil}, watched, order, cards) do
    # Never imported, so nothing is known about it yet — one request, here, where
    # the page is already fetching and says so.
    case Laev.Anime.learn(mal_id) do
      %{} = learned -> unfinished_anime_title({mal_id, learned}, watched, order, cards)
      _ -> nil
    end
  end

  defp unfinished_anime_title({mal_id, anime}, watched, order, cards) do
    case Laev.AnimeMap.tmdb(mal_id) do
      {type, tmdb_id, _season} -> anime_row(anime, mal_id, type, tmdb_id, watched, order, cards)
      {type, tmdb_id} -> anime_row(anime, mal_id, type, tmdb_id, watched, order, cards)
      _ -> nil
    end
  end

  defp anime_row(anime, mal_id, type, tmdb_id, watched, order, cards) do
    details = Map.get(cards, {type, tmdb_id}, %{})

    details
    |> unfinished_row(type, tmdb_id)
    |> Map.merge(%{
      title: anime.title || details["name"] || details["title"],
      mal_id: mal_id,
      note: anime_progress_note(anime, watched),
      # Said rather than left out: every row on this page is asked whether it is
      # caught up, and an anime in progress has episodes waiting by definition.
      caught_up: false,
      held: anime.status == "on_hold",
      # MAL's own timestamp, or laev's if it played this here more recently —
      # either way, when you last watched it.
      watched_at: max(anime[:updated] || 0, last_watched_at(type, tmdb_id)),
      order: order
    })
  end

  # "7/24 episodes", with "on hold" said out loud — the difference between
  # something you are watching and something you put down.
  defp anime_progress_note(anime, 0), do: if(anime.status == "on_hold", do: " · on hold", else: "")

  defp anime_progress_note(anime, watched) do
    held = if anime.status == "on_hold", do: " · on hold", else: ""

    case anime.episodes do
      total when is_integer(total) and total > 0 -> "#{held} · #{watched}/#{total} episodes"
      _ -> "#{held} · #{watched} episode#{if watched > 1, do: "s"} watched"
    end
  end

  # Saved once, after the fetching: this is what lets the home screen leave the
  # shows you are only waiting on out of its count without fetching anything.
  defp remember_aired_seasons(titles) do
    titles
    |> Enum.filter(&(&1[:aired_seasons] && &1.type == "tv"))
    |> Map.new(&{&1.id, &1[:aired_seasons]})
    |> Laev.Seasons.put_aired_seasons_many()

    titles
  end

  @doc """
  The Watchlist page in order, with a dim line before each section that isn't
  the first.

  Three sections, because there are three answers to "why isn't this finished":
  you are in the middle of it, you are up to date and waiting, or you put it
  down. Only the first is a list of things to do tonight, which is what the home
  screen counts — the other two are there to be looked through, not worked
  through, so they sit below a divider each.

  Public because it is the one part of that page with a rule in it: a row that
  says nothing about being caught up or held is in the middle of being watched,
  which is how anime rows arrive.
  """
  def divide_sections(rows) do
    grouped = Enum.group_by(rows, &section_of/1)

    # Most recently watched first, within every section — the point of the page
    # being that what you had on last night is the thing you want tonight, one
    # keypress in, not somewhere alphabetical. Rows with no timestamp keep the
    # order they arrived in.
    ordered = fn section ->
      grouped |> Map.get(section, []) |> Enum.sort_by(&{-rank(&1, :watched_at), rank(&1, :order)})
    end

    ordered.(:behind) ++
      divided(:caught_up, ordered.(:caught_up)) ++ divided(:on_hold, ordered.(:on_hold))
  end

  @doc "Which section a Watchlist row belongs to."
  # Scenery that found its way in sits in the first section rather than taking
  # the page down — the same reason title_poster/1 answers for anything.
  def section_of(row) when not is_map(row), do: :behind

  def section_of(row) do
    cond do
      row[:held] == true -> :on_hold
      row[:caught_up] == true -> :caught_up
      true -> :behind
    end
  end

  defp divided(_divider, []), do: []

  defp divided(divider, rows), do: [divider | rows]

  # Rows are maps; anything else is scenery and sorts as zero rather than raising
  # on a field it hasn't got.
  defp rank(row, key) when is_map(row), do: row[key] || 0

  defp rank(_row, _key), do: 0

  # "2 of 4 seasons", and whether there is anything to watch right now.  # "2 of 4 seasons", and whether there is anything to watch right now.
  #
  # A show whose every aired season is behind you is not behind — it is caught
  # up, and saying so is the difference between "go and watch this" and "wait for
  # the next one". Counted from the details the row already fetched, so the
  # numbers are TMDB's rather than a guess from what laev happens to have looked
  # at.
  defp season_progress_note(details, marks) do
    real = Enum.filter(details["seasons"] || [], &(&1["season_number"] > 0))
    today = Date.to_iso8601(Date.utc_today())

    aired = Enum.filter(real, &(&1["air_date"] not in [nil, ""] and &1["air_date"] <= today))

    watched =
      Enum.count(aired, fn season ->
        number = season["season_number"]
        total = Laev.Seasons.aired(details["id"], number) || season["episode_count"] || 0

        total > 0 and Map.get(marks, number, 0) >= total
      end)

    # Caught up is simply "every season that exists to watch is watched" —
    # whether or not TMDB has announced another one. A show with all four of its
    # four seasons behind you has nothing for you tonight, which is the thing
    # worth saying and the reason it sinks down the list.
    caught_up? = aired != [] and watched == length(aired)

    marked = marks |> Map.values() |> Enum.sum()
    episodes = Enum.reduce(aired, 0, fn season, sum -> sum + (season["episode_count"] || 0) end)

    # Counted against the seasons that are actually out, not the ones TMDB lists.
    # It carries a placeholder for anything announced — Dune: Prophecy has a
    # season 2 with no air date at all — and counting those turns "caught up on
    # all 3" into "3/4", which reads as a season behind.
    note =
      cond do
        caught_up? -> " · caught up · #{watched}/#{length(aired)} seasons"
        watched > 0 -> " · #{watched}/#{length(aired)} seasons watched"
        # Not a season in yet: the episode count says far more than "0/1".
        marked > 0 and episodes > 0 -> " · #{marked}/#{episodes} episodes watched"
        marked > 0 -> " · #{marked} episode#{if marked > 1, do: "s"} watched"
        true -> ""
      end

    %{note: note, caught_up: caught_up?, aired_seasons: length(aired)}
  end

  defp unfinished_row(details, type, id) do
    %{
      id: id,
      type: type,
      held: Laev.Holds.held?(type, id),
      watched_at: last_watched_at(type, id),
      title: details["name"] || details["title"] || Laev.Titles.get(type, id) || "#{type} ##{id}",
      year: Tmdb.year(details["first_air_date"] || details["release_date"]),
      poster: Tmdb.poster_url(details["poster_path"], "w342"),
      overview: details["overview"],
      vote: details["vote_average"],
      popularity: details["popularity"]
    }
  end

  # Open on the one you would watch next: the first that isn't behind you. A
  # list is opened to carry on through it, and landing on film one of a series
  # you are three into means scrolling past your own checkmarks every time.
  # Everything watched leaves the cursor at the top, where there is nothing
  # pending to point at anyway.
  def first_unwatched_title(titles) do
    Enum.find_index(titles, &(not seen?(&1))) || 0
  end

  # A film counts as seen once it is played through (85%/eof writes the same
  # marker), a series only when ctrl-w says so — laev can't tell a finished
  # series from an abandoned one, so that stays a deliberate act rather than
  # a guess.
  def seen?(t), do: Laev.Position.finished?(title_ctx(t)) or anime_seen?(t)

  # Anime is marked by MyAnimeList entry, and a search row is a TMDB row — so a
  # row for something whose every MAL entry is finished is a row for something
  # watched. Every part: Lupin III is seven anime on MAL, and having seen six of
  # them is not having seen Lupin III.
  defp anime_seen?(%{type: type, id: id}) when is_integer(id) do
    case Laev.AnimeMap.mal_ids(type, id) do
      [] -> false
      ids -> Enum.all?(ids, &(Laev.Position.mark_state(%{mal_id: &1}) == :watched))
    end
  end

  defp anime_seen?(_title), do: false

  # "240 episodes watched" for a row whose marks all live under MAL ids. Same
  # wording the TMDB path uses, because it means the same thing.
  def anime_watched_note(%{type: type, id: id}) when is_integer(id) do
    marks = anime_marks()
    counted = Laev.AnimeMap.mal_ids(type, id) |> Enum.map(&Map.get(marks, &1, 0)) |> Enum.sum()

    if counted > 0, do: " · #{counted} episode#{if counted > 1, do: "s"} watched", else: ""
  end

  def anime_watched_note(_title), do: ""

  def complete_season?(id, season, marked) do
    case Laev.Seasons.aired(id, season) do
      aired when is_integer(aired) and aired > 0 -> marked >= aired
      _ -> false
    end
  end

  # Read once per screen rather than once per row: twenty rows each scanning the
  # positions directory is twenty scans of a thousand files.
  def marks_by_show, do: SessionCache.fetch(:episode_marks, 2, &Laev.Position.episode_marks/0)

  # Anime marks, read once per screen like the show marks beside them — both of
  # these are asked for by the home screen, which redraws on every keypress.
  def anime_marks, do: SessionCache.fetch(:anime_marks, 2, &Laev.Position.anime_marks/0)

  def anime_finished, do: SessionCache.fetch(:anime_finished, 2, &Laev.Position.anime_finished/0)

  def anime_list, do: SessionCache.fetch(:anime_list, 2, &Laev.Anime.all/0)

  # Whole shows marked watched — the bare tv-<id> marks, which is what "finished
  # a series" means on disk.
  def series_marks do
    dir = Path.join(Laev.Scope.dir(), "positions")

    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &Regex.match?(~r/^tv-\d+$/, &1))
      _ -> []
    end
  end
  # The only thing this module wants from TMDB.
  defp details("movie", id), do: Tmdb.movie(id)
  defp details("tv", id), do: Tmdb.tv(id)
  defp details(_type, _id), do: {:error, :unknown_type}

  # Enough of a context for Position to find its key. The playback context
  # proper belongs to the part that plays, not to the page that lists.
  defp resume_ctx(entry) do
    %{
      type: entry["type"],
      tmdb_id: entry["tmdb_id"],
      season: entry["season"],
      episode: entry["episode"],
      mal_id: entry["mal_id"]
    }
  end

  defp title_ctx(%{mal_id: mal_id} = title) when is_integer(mal_id),
    do: %{type: title[:type], tmdb_id: title[:id], season: nil, episode: nil, mal_id: mal_id}

  defp title_ctx(%{type: type, id: id}) when type in ["movie", "tv"] and is_integer(id),
    do: %{type: type, tmdb_id: id, season: nil, episode: nil}

  defp title_ctx(_title), do: %{type: nil, tmdb_id: nil, season: nil, episode: nil}
end
