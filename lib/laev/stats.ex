defmodule Laev.Stats do
  @moduledoc """
  What you've watched, totalled.

  The position files are the record: one per film or episode, holding either
  the second you reached or `"done"`. That is enough to say *what* was
  watched but not *how long* — a finished film leaves only the word "done" —
  so runtimes come from TMDB and are cached in `runtimes.json`, one lookup per
  film and one per *show* rather than per episode.

  Time comes in two kinds, kept apart because they are known to very
  different degrees:

    * **in laev** — played here. Either measured second by second by the mpv
      script, or taken as the runtime of something laev watched you finish.
    * **off laev** — marked watched by hand with ctrl-w. You watched it; laev
      has no idea how much of it, or when, so it assumes the full runtime and
      never pretends that figure was observed.

  Anime is counted apart, and from MyAnimeList rather than TMDB: a mark there is
  one anime's episode (`mal-1425-e12`), and MAL reports how long an episode of
  that anime runs — which TMDB frequently doesn't for anime at all. So anime
  hours are its own figure, derived from its own source, and sit beside films and
  shows instead of inside them.

  Nothing is invented. An entry whose runtime can't be established is counted
  as watched but left out of the time, and reported separately, so the total
  is only ever made of durations that were actually known.
  """

  alias Laev.Tmdb

  @cache "runtimes.json"
  # TMDB gives a show's typical episode length; a few shows list none at all.
  @unknown :unknown

  defmodule Title do
    @moduledoc false
    defstruct [:type, :tmdb_id, :title, seconds: 0, off: 0, finished: 0, started: 0, whole: false]
  end

  @doc """
  All-time totals: seconds watched, how many films and episodes, and the
  titles you've given the most time to.

  Returns `%{seconds:, in_laev:, off_laev:, films:, episodes:, shows:, titles:
  [%Title{}], unknown:, skipped:, measured:, anime:, other:}` with `titles`
  sorted by time spent, and `anime`/`other` holding the same counts for the two
  halves of what you watch. `seconds` is the two buckets added together. `skipped` counts only
  plays laev measured, so it starts at nothing and grows from here.
  """
  def all_time do
    entries = read_positions()
    runtimes = runtimes_for(entries)
    played = read_played()

    {titles, unknown, skipped, measured} = fold(entries, runtimes, played)
    titles = name_the_rest(titles)
    off = titles |> Enum.map(& &1.off) |> Enum.sum()
    total = titles |> Enum.map(& &1.seconds) |> Enum.sum()

    %{
      seconds: total,
      in_laev: total - off,
      off_laev: off,
      films: count_kind(entries, :movie),
      episodes: count_kind(entries, :episode),
      shows: count_shows(entries),
      marked: Enum.count(entries, fn {_n, _t, _i, _k, p} -> p == :seen end),
      titles: Enum.sort_by(titles, & &1.seconds, :desc),
      unknown: unknown,
      skipped: skipped,
      measured: measured,
      anime: slice(titles, entries, true),
      other: slice(titles, entries, false)
    }
  end

  # Anime kept apart from everything else, because they are not the same hobby:
  # three hundred twenty-minute episodes and sixty films both come to "a year of
  # evenings" and nothing else about them compares. No guessing is involved —
  # anime is what MyAnimeList holds, and its marks say so in their own keys.
  defp slice(titles, entries, anime?) do
    mine = Enum.filter(titles, &((&1.type == "mal") == anime?))
    rows = Enum.filter(entries, fn {_n, type, _id, _k, _p} -> (type == "mal") == anime? end)

    %{
      seconds: mine |> Enum.map(& &1.seconds) |> Enum.sum(),
      titles: length(mine),
      films: count_kind(rows, :movie),
      episodes: count_kind(rows, :episode),
      shows: count_shows(rows)
    }
  end

  @doc """
  What one title holds: seconds watched and how many saved entries it spans.

  Asked before erasing it, so the question "remove this?" can say what is
  actually at stake — a film is a couple of hours, a show can be thirty.
  """
  def for_title(type, tmdb_id) do
    entries = Enum.filter(read_positions(), fn {_n, t, id, _k, _p} -> t == type and id == tmdb_id end)
    {titles, _unknown, _skipped, _measured} = fold(entries, runtimes_for(entries), read_played())

    %{seconds: titles |> Enum.map(& &1.seconds) |> Enum.sum(), entries: length(entries)}
  end

  # A title whose runtime was already cached never got looked up, so its name was
  # never learned — which is every row on a page built before names were kept.
  # The leftovers are asked for directly, once, and then cached like the rest.
  #
  # All of them, not a batch: capping it meant a page of a thousand imported
  # titles named a hundred per visit and still read as ids for the next nine.
  defp name_the_rest(titles) do
    missing = Enum.filter(titles, &(&1.title == "#{&1.type} ##{&1.tmdb_id}"))

    if missing == [] do
      titles
    else
      if length(missing) > 20,
        do: IO.puts(:stderr, IO.ANSI.format([:faint, "  naming #{length(missing)} titles — one-time…", :reset]))

      found =
        missing
        |> Task.async_stream(&{{&1.type, &1.tmdb_id}, name_of(&1.type, &1.tmdb_id)},
          max_concurrency: 8,
          timeout: 15_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {key, name}} when is_binary(name) -> [{key, name}]
          _ -> []
        end)
        |> Map.new()

      Laev.Titles.put(found)

      Enum.map(titles, fn title ->
        case Map.get(found, {title.type, title.tmdb_id}) do
          nil -> title
          name -> %{title | title: name}
        end
      end)
    end
  end

  defp name_of("movie", id) do
    with {:ok, %{"title" => title}} <- Tmdb.movie(id), do: title, else: (_ -> nil)
  end

  defp name_of("tv", id) do
    with {:ok, %{"name" => name}} <- Tmdb.tv(id), do: name, else: (_ -> nil)
  end

  defp name_of("mal", id), do: Laev.Anime.title(id) || with(%{title: title} <- Laev.Anime.learn(id), do: title, else: (_ -> nil))

  defp name_of(_type, _id), do: nil

  @doc "Seconds as `12h 04m`, or `48m` under an hour."
  def duration(seconds) when is_integer(seconds) and seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if hours > 0, do: "#{hours}h #{String.pad_leading(to_string(minutes), 2, "0")}m", else: "#{minutes}m"
  end

  def duration(_), do: "0m"

  # ── the position files ────────────────────────────────────────────

  # Each becomes {type, tmdb_id, kind, progress}. A bare `tv-<id>` is the
  # ctrl-w "I've seen this" mark on a whole series — there's no honest number
  # of hours for "all of Game of Thrones", so it counts as watched, not time.
  defp read_positions do
    dir = Path.join(data_dir(), "positions")
    # Read once: a bare `mal-<id>` is a whole anime, and whether that is a film
    # or a series is something only the anime's own episode count can say.
    anime = Laev.Anime.all()

    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, &parse(&1, File.read(Path.join(dir, &1)), anime))

      _ ->
        []
    end
  end

  defp parse(name, {:ok, body}, anime) do
    progress =
      case String.trim(body) do
        "done" -> :done
        "seen" -> :seen
        digits -> with {n, _} <- Integer.parse(digits), do: {:secs, n}, else: (_ -> nil)
      end

    case {key_parts(name, anime), progress} do
      {nil, _} -> []
      {_, nil} -> []
      {{type, id, kind}, progress} -> [{name, type, id, kind, progress}]
    end
  end

  defp parse(_name, _body, _anime), do: []

  defp key_parts(name, anime) do
    cond do
      # a film
      match = Regex.run(~r/^movie-(\d+)$/, name) -> {"movie", String.to_integer(Enum.at(match, 1)), :movie}
      # an episode, numbered by season or absolutely
      match = Regex.run(~r/^tv-(\d+)-(?:s\d+)?e\d+$/, name) -> {"tv", String.to_integer(Enum.at(match, 1)), :episode}
      # the whole series, marked by hand
      match = Regex.run(~r/^tv-(\d+)$/, name) -> {"tv", String.to_integer(Enum.at(match, 1)), :series_mark}
      # one episode of one anime, as MyAnimeList counts it
      match = Regex.run(~r/^mal-(\d+)-e\d+$/, name) -> {"mal", String.to_integer(Enum.at(match, 1)), :episode}
      # a whole anime: a film if that is all it is, a finished series otherwise
      match = Regex.run(~r/^mal-(\d+)$/, name) -> whole_anime(String.to_integer(Enum.at(match, 1)), anime)
      true -> nil
    end
  end

  # A one-episode anime is a film (or an OVA, which is a film as far as an
  # evening is concerned); anything longer is a series you finished.
  defp whole_anime(id, anime) do
    case anime[id] do
      %{episodes: 1} -> {"mal", id, :movie}
      _ -> {"mal", id, :series_mark}
    end
  end

  defp count_kind(entries, kind), do: Enum.count(entries, fn {_n, _t, _i, k, _p} -> k == kind end)

  # How many separate shows those episodes came from — 46 episodes reads very
  # differently depending on whether it is one series or thirteen.
  defp count_shows(entries) do
    entries
    |> Enum.filter(fn {_n, _t, _i, kind, _p} -> kind == :episode end)
    |> Enum.map(fn {_n, type, id, _kind, _p} -> {type, id} end)
    |> Enum.uniq()
    |> length()
  end

  # What the mpv script measured: seconds truly played, and seconds seeked
  # past. Only exists for plays since laev started counting, so it refines
  # the estimate where it can and is simply absent everywhere else.
  defp read_played do
    dir = Path.join(data_dir(), "played")

    case File.ls(dir) do
      {:ok, names} ->
        Map.new(names, fn name ->
          with {:ok, body} <- File.read(Path.join(dir, name)),
               [w, s] <- String.split(String.trim(body), " ", parts: 2),
               {watched, _} <- Integer.parse(w),
               {skipped, _} <- Integer.parse(s) do
            {name, %{watched: watched, skipped: skipped}}
          else
            _ -> {name, nil}
          end
        end)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      _ ->
        %{}
    end
  end

  # ── runtimes, cached ──────────────────────────────────────────────

  # One lookup per film and per show — an episode borrows its show's typical
  # length, which is what TMDB reports and is close enough for a total.
  defp runtimes_for(entries) do
    cached = load_cache()

    wanted =
      entries
      |> Enum.map(fn {_n, type, id, kind, _p} -> runtime_key(type, id, kind) end)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(cached, cache_key(&1)))

    fetched =
      wanted
      |> Task.async_stream(&{cache_key(&1), fetch_runtime(&1)},
        max_concurrency: 8,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {key, value}} -> [{key, value}]
        _ -> []
      end)
      |> Map.new()

    merged = Map.merge(cached, fetched)
    if fetched != %{}, do: save_cache(merged)
    merged
  end

  defp cache_key({type, id}), do: "#{type}-#{id}"

  # "I've seen all of it" needs the length of the whole run, so a series mark
  # is looked up under its own key rather than borrowing the episode length.
  defp runtime_key("mal", id, kind) when kind in [:series_mark, :movie], do: {"mal_all", id}
  defp runtime_key(_type, id, :series_mark), do: {"series", id}
  defp runtime_key(type, id, _kind), do: {type, id}

  # Seconds, or `@unknown` when TMDB lists none — cached either way, so a show
  # without runtimes isn't looked up again on every run.
  defp fetch_runtime({"movie", id}) do
    case Tmdb.movie(id) do
      {:ok, %{"runtime" => minutes} = movie} when is_integer(minutes) and minutes > 0 ->
        remember_name("movie", id, movie["title"])
        minutes * 60

      {:ok, movie} ->
        remember_name("movie", id, movie["title"])
        @unknown

      _ ->
        @unknown
    end
  end

  defp fetch_runtime({"tv", id}) do
    case Tmdb.tv(id) do
      {:ok, show} ->
        remember_name("tv", id, show["name"])
        episode_seconds(show)

      _ ->
        @unknown
    end
  end

  # Anime, from MyAnimeList's own numbers: how long one episode of this anime
  # runs, and how long all of it does. Asked of the list once and kept, so the
  # only anime laev ever looks up is one it played that the list didn't cover.
  defp fetch_runtime({"mal", id}) do
    case Laev.Anime.learn(id) do
      %{seconds: seconds} when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @unknown
    end
  end

  defp fetch_runtime({"mal_all", id}) do
    case Laev.Anime.learn(id) do
      %{seconds: seconds, episodes: count} when is_integer(seconds) and seconds > 0 and is_integer(count) and count > 0 ->
        seconds * count

      _ ->
        @unknown
    end
  end

  # Every episode there is — what marking a whole series claims you watched.
  defp fetch_runtime({"series", id}) do
    with {:ok, show} <- Tmdb.tv(id),
         seconds when is_integer(seconds) <- episode_seconds(show),
         count when is_integer(count) and count > 0 <- show["number_of_episodes"] do
      count * seconds
    else
      _ -> @unknown
    end
  end

  # The name comes free with the runtime — the same response carries both — so a
  # title laev has never played still has something readable to show.
  defp remember_name(type, id, name) when is_binary(name) and name != "",
    do: Laev.Titles.put(%{{type, id} => name})

  defp remember_name(_type, _id, _name), do: :ok

  defp episode_seconds(%{"episode_run_time" => [minutes | _]}) when is_integer(minutes) and minutes > 0,
    do: minutes * 60

  defp episode_seconds(%{"last_episode_to_air" => %{"runtime" => minutes}}) when is_integer(minutes) and minutes > 0,
    do: minutes * 60

  defp episode_seconds(_), do: @unknown

  defp load_cache do
    with {:ok, body} <- File.read(Path.join(data_dir(), @cache)),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Map.new(map, fn {k, v} -> {k, if(v == "unknown", do: @unknown, else: v)} end)
    else
      _ -> %{}
    end
  end

  defp save_cache(map) do
    wire = Map.new(map, fn {k, v} -> {k, if(v == @unknown, do: "unknown", else: v)} end)
    File.write(Path.join(data_dir(), @cache), Jason.encode!(wire))
  rescue
    _ -> :ok
  end

  # ── folding it together ───────────────────────────────────────────

  defp fold(entries, runtimes, played) do
    titles = Laev.Resume.all() |> Map.new(&{{&1["type"], &1["tmdb_id"]}, &1["title"]})
    names = {titles, Laev.Titles.all()}

    # Series marks go last, and knowingly: "I have seen this show" claims the
    # whole run, and some of that run is already counted episode by episode. An
    # anime imported from a list arrives both ways — 24 episode marks and the
    # show marked finished — and billing both would charge the season twice.
    {marks, rest} = Enum.split_with(entries, fn {_n, _t, _i, kind, _p} -> kind == :series_mark end)

    rest
    |> Enum.reduce({%{}, 0, 0, 0}, &fold_entry(&1, &2, runtimes, played, names))
    |> then(fn state -> Enum.reduce(marks, state, &fold_series(&1, &2, runtimes, names)) end)
    |> then(fn {acc, unknown, skipped, measured} -> {Map.values(acc), unknown, skipped, measured} end)
  end

  defp fold_entry({name, type, id, kind, progress}, {acc, unknown, skipped, measured}, runtimes, played, names) do
    key = {type, id}
    runtime = Map.get(runtimes, cache_key(runtime_key(type, id, kind)))

    case {Map.get(played, name), seconds_for(progress, runtime)} do
      # Measured: the seconds really played here, and what was seeked past.
      {%{watched: watched, skipped: past}, _} ->
        {bump(acc, key, names, watched, 0, progress), unknown, skipped + past, measured + 1}

      {_, :unknown} ->
        {bump(acc, key, names, 0, 0, progress), unknown + 1, skipped, measured}

      # Marked by hand: the full runtime, all of it off-laev.
      {_, {:off, seconds}} ->
        {bump(acc, key, names, seconds, seconds, progress), unknown, skipped, measured}

      {_, seconds} ->
        {bump(acc, key, names, seconds, 0, progress), unknown, skipped, measured}
    end
  end

  # What a whole-show mark adds on top of its episodes: the rest of the run. A
  # show marked watched with nothing else known about it still counts for all of
  # it; one whose every episode is already marked adds nothing.
  defp fold_series({_name, type, id, _kind, progress}, {acc, unknown, skipped, measured}, runtimes, names) do
    key = {type, id}
    counted = with %Title{seconds: seconds} <- Map.get(acc, key), do: seconds, else: (_ -> 0)

    case Map.get(runtimes, cache_key(runtime_key(type, id, :series_mark))) do
      whole when is_integer(whole) ->
        rest = max(whole - counted, 0)
        {bump(acc, key, names, rest, rest, progress, true), unknown, skipped, measured}

      _ ->
        {bump(acc, key, names, 0, 0, progress, true), unknown + 1, skipped, measured}
    end
  end

  # A part-watched entry is worth the seconds it reached; a finished one is
  # worth its runtime, which is the only place the runtime lookup is needed.
  # A hand mark is worth its runtime too — ctrl-w says you watched it — but
  # comes back tagged, because that runtime is an assumption, not a reading.
  defp seconds_for({:secs, seconds}, _runtime), do: seconds
  defp seconds_for(:seen, runtime) when is_integer(runtime), do: {:off, runtime}
  defp seconds_for(:done, runtime) when is_integer(runtime), do: runtime
  defp seconds_for(progress, _runtime) when progress in [:done, :seen], do: :unknown

  defp bump(acc, key, names, seconds, off, progress, whole? \\ false)

  defp bump(acc, {type, id} = key, {titles, known}, seconds, off, progress, whole?) do
    entry =
      Map.get(acc, key, %Title{
        type: type,
        tmdb_id: id,
        title: Map.get(titles, key) || Map.get(known, "#{type}-#{id}") || "#{type} ##{id}"
      })

    entry = %{entry | seconds: entry.seconds + seconds, off: entry.off + off}

    # A whole-title mark is not another episode. Counting it as one is how 155
    # episodes of Lupin III: Part II came to read as 156 watched — the series mark
    # is a statement *about* those episodes, so it says "watched through" instead
    # of adding to their tally.
    entry =
      cond do
        whole? -> %{entry | whole: true}
        progress in [:done, :seen] -> %{entry | finished: entry.finished + 1}
        true -> %{entry | started: entry.started + 1}
      end

    Map.put(acc, key, entry)
  end

  defp data_dir do
    Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
  end
end
