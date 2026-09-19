defmodule Laev.Stats do
  @moduledoc """
  What you've watched, totalled.

  The position files are the record: one per film or episode, holding either
  the second you reached or `"done"`. That is enough to say *what* was
  watched but not *how long* — a finished film leaves only the word "done" —
  so runtimes come from TMDB and are cached in `runtimes.json`, one lookup per
  film and one per *show* rather than per episode.

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
    defstruct [:type, :tmdb_id, :title, seconds: 0, finished: 0, started: 0]
  end

  @doc """
  All-time totals: seconds watched, how many films and episodes, and the
  titles you've given the most time to.

  Returns `%{seconds:, films:, episodes:, shows:, titles: [%Title{}], unknown:,
  skipped:, measured:}` with `titles` sorted by time spent. `skipped` counts
  only plays laev measured, so it starts at nothing and grows from here.
  """
  def all_time do
    entries = read_positions()
    runtimes = runtimes_for(entries)
    played = read_played()

    {titles, unknown, skipped, measured} = fold(entries, runtimes, played)

    %{
      seconds: titles |> Enum.map(& &1.seconds) |> Enum.sum(),
      films: count_kind(entries, :movie),
      episodes: count_kind(entries, :episode),
      shows: count_shows(entries),
      marked: Enum.count(entries, fn {_n, _t, _i, _k, p} -> p == :seen end),
      titles: Enum.sort_by(titles, & &1.seconds, :desc),
      unknown: unknown,
      skipped: skipped,
      measured: measured
    }
  end

  @doc "Seconds as `12h 04m`, or `48m` under an hour."
  def duration(seconds) when is_integer(seconds) and seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if hours > 0, do: "#{hours}h #{String.pad_leading(to_string(minutes), 2, "0")}m", else: "#{minutes}m"
  end

  def duration(_), do: "0m"

  # ── the position files ────────────────────────────────────────────

  # Each becomes {type, tmdb_id, kind, progress}. A bare `tv-<id>` is the
  # ctrl-w "I've seen this" mark on a whole series: a statement, not a
  # measured play, so it never contributes time.
  defp read_positions do
    dir = Path.join(data_dir(), "positions")

    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, &parse(&1, File.read(Path.join(dir, &1))))

      _ ->
        []
    end
  end

  defp parse(name, {:ok, body}) do
    progress =
      case String.trim(body) do
        "done" -> :done
        "seen" -> :seen
        digits -> with {n, _} <- Integer.parse(digits), do: {:secs, n}, else: (_ -> nil)
      end

    case {key_parts(name), progress} do
      {nil, _} -> []
      {_, nil} -> []
      {{type, id, kind}, progress} -> [{name, type, id, kind, progress}]
    end
  end

  defp parse(_name, _), do: []

  defp key_parts(name) do
    cond do
      # a film
      match = Regex.run(~r/^movie-(\d+)$/, name) -> {"movie", String.to_integer(Enum.at(match, 1)), :movie}
      # an episode, numbered by season or absolutely (anime)
      match = Regex.run(~r/^tv-(\d+)-(?:s\d+)?e\d+$/, name) -> {"tv", String.to_integer(Enum.at(match, 1)), :episode}
      # the whole series, marked by hand
      match = Regex.run(~r/^tv-(\d+)$/, name) -> {"tv", String.to_integer(Enum.at(match, 1)), :series_mark}
      true -> nil
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
      |> Enum.reject(fn {_n, _t, _i, kind, p} -> kind == :series_mark or p == :seen end)
      |> Enum.map(fn {_n, type, id, _kind, _p} -> {type, id} end)
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

  # Seconds, or `@unknown` when TMDB lists none — cached either way, so a show
  # without runtimes isn't looked up again on every run.
  defp fetch_runtime({"movie", id}) do
    case Tmdb.movie(id) do
      {:ok, %{"runtime" => minutes}} when is_integer(minutes) and minutes > 0 -> minutes * 60
      _ -> @unknown
    end
  end

  defp fetch_runtime({"tv", id}) do
    case Tmdb.tv(id) do
      {:ok, %{"episode_run_time" => [minutes | _]}} when is_integer(minutes) and minutes > 0 ->
        minutes * 60

      {:ok, %{"last_episode_to_air" => %{"runtime" => minutes}}} when is_integer(minutes) and minutes > 0 ->
        minutes * 60

      _ ->
        @unknown
    end
  end

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
    empty = {%{}, 0, 0, 0}

    Enum.reduce(entries, empty, fn {name, type, id, kind, progress}, {acc, unknown, skipped, measured} ->
      case {kind, Map.get(played, name)} do
        {:series_mark, _} ->
          {acc, unknown, skipped, measured}

        # Measured: the seconds really played, and what was seeked past.
        {_, %{watched: watched, skipped: past}} ->
          {bump(acc, {type, id}, titles, watched, progress), unknown, skipped + past, measured + 1}

        _ ->
          case seconds_for(kind, progress, Map.get(runtimes, "#{type}-#{id}")) do
            :skip -> {acc, unknown, skipped, measured}
            :marked -> {bump(acc, {type, id}, titles, 0, progress), unknown, skipped, measured}
            :unknown -> {bump(acc, {type, id}, titles, 0, progress), unknown + 1, skipped, measured}
            seconds -> {bump(acc, {type, id}, titles, seconds, progress), unknown, skipped, measured}
          end
      end
    end)
    |> then(fn {acc, unknown, skipped, measured} -> {Map.values(acc), unknown, skipped, measured} end)
  end

  # A part-watched entry is worth the seconds it reached; a finished one is
  # worth its runtime, which is the only place the runtime lookup is needed.
  defp seconds_for(:series_mark, _progress, _runtime), do: :skip
  # Marked by hand: watched, but not time laev can claim to have measured.
  defp seconds_for(_kind, :seen, _runtime), do: :marked
  defp seconds_for(_kind, {:secs, seconds}, _runtime), do: seconds
  defp seconds_for(_kind, :done, runtime) when is_integer(runtime), do: runtime
  defp seconds_for(_kind, :done, _), do: :unknown

  defp bump(acc, {type, id} = key, titles, seconds, progress) do
    entry =
      Map.get(acc, key, %Title{
        type: type,
        tmdb_id: id,
        title: Map.get(titles, key) || "#{type} ##{id}"
      })

    entry = %{entry | seconds: entry.seconds + seconds}

    entry =
      case progress do
        p when p in [:done, :seen] -> %{entry | finished: entry.finished + 1}
        _ -> %{entry | started: entry.started + 1}
      end

    Map.put(acc, key, entry)
  end

  defp data_dir do
    Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
  end
end
