defmodule Laev.AnimeMap do
  @moduledoc """
  Which MyAnimeList entry is which TMDB title.

  The two sites count anime differently and share no ids. MAL lists a *season*
  as its own entry — "Attack on Titan", "Attack on Titan Season 2" and "Final
  Season" are three anime with three ids — while TMDB keeps one show with three
  seasons. Matching them by title is guesswork (sequels, ONAs, recap editions
  and twelve romanisations of the same name), so laev doesn't: it uses the
  community cross-id list, which pins each MAL id to a TMDB id *and the season
  number* it corresponds to.

  The published file is 7.5MB of ids for every site there is. It's fetched once,
  trimmed to the two columns laev needs, and kept in `anime-map.json` — about a
  twentieth of the size and loaded in a millisecond. Lookups never reach the
  network: a list that pauses to download something is a list that stutters, so
  a missing map answers `nil` and leaves the fetching to `ensure/1`, which runs
  where a pause is expected and explained.
  """

  @url "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json"
  @cache "anime-map.json"
  # The list gains entries as new anime air; a month-old copy is missing only
  # things that premiered since, which is nothing anyone has finished yet.
  @max_age 30 * 24 * 3600

  @doc """
  Where a MAL id lives on TMDB: `{"tv", id, season}`, `{"movie", id}`, or nil
  when the map doesn't know it (or hasn't been fetched).

  The direction laev needs when something keyed by MAL entry has to find the TMDB
  title it was played as — forgetting an anime's history, for one.
  """
  def tmdb(mal_id) when is_integer(mal_id) do
    case Map.get(load().forward, Integer.to_string(mal_id)) do
      ["tv", id, season] -> {"tv", id, season}
      ["movie", id] -> {"movie", id}
      _ -> nil
    end
  end

  def tmdb(_mal_id), do: nil

  @doc """
  The MAL id for a TMDB show's season (or a film) — the reverse direction,
  used to scrobble something laev found on TMDB to the right MAL entry.
  """
  def mal_id("tv", tmdb_id, season) when is_integer(tmdb_id) do
    Map.get(load().tv, "#{tmdb_id}-#{season || 1}")
  end

  def mal_id("movie", tmdb_id, _season) when is_integer(tmdb_id) do
    Map.get(load().movie, Integer.to_string(tmdb_id))
  end

  def mal_id(_type, _tmdb_id, _season), do: nil

  @doc """
  Every MAL entry that is part of this TMDB title.

  A TMDB show can be many anime: Lupin III is seven entries on MAL and one show
  with seven seasons here. Which is why laev marks anime by MAL entry — but a
  search row is still a TMDB row, and this is how it finds out what it is made of.
  """
  def mal_ids("tv", tmdb_id) when is_integer(tmdb_id) do
    load().forward
    |> Enum.flat_map(fn
      {mal, ["tv", ^tmdb_id, _season]} -> [String.to_integer(mal)]
      _ -> []
    end)
    |> Enum.sort()
  end

  def mal_ids("movie", tmdb_id) when is_integer(tmdb_id) do
    case mal_id("movie", tmdb_id, nil) do
      id when is_integer(id) -> [id]
      _ -> []
    end
  end

  def mal_ids(_type, _tmdb_id), do: []

  @doc """
  True when this TMDB title is anime — it appears in the cross-id list, which
  is a list of anime and nothing else.

  Used to split the stats, so it must answer offline and instantly for every
  row on the page. An unfetched map calls nothing anime rather than guessing.
  """
  def anime?("tv", tmdb_id) when is_integer(tmdb_id), do: MapSet.member?(load().tv_ids, tmdb_id)
  def anime?("movie", tmdb_id) when is_integer(tmdb_id), do: MapSet.member?(load().movie_ids, tmdb_id)
  def anime?(_type, _id), do: false

  @doc "True once the map is on disk (whatever its age)."
  def ready?, do: File.exists?(path())

  @doc """
  Make sure the map is present and not stale, fetching it if it isn't.

  Returns `{:ok, count}` | `{:error, reason}`. `report` is called with a line
  before a download, so the wait has a reason attached to it.
  """
  def ensure(report \\ fn _line -> :ok end) do
    if fresh?(), do: {:ok, map_size(load().forward)}, else: refresh(report)
  end

  @doc "Fetch the cross-id list and rewrite the trimmed cache."
  def refresh(report \\ fn _line -> :ok end) do
    report.("learning which anime is which on TMDB — one-time…")

    # Served as text/plain, so Req hands back a string rather than parsed JSON.
    case Req.get(@url, retry: false, receive_timeout: 90_000, connect_options: [timeout: 15_000]) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, entries} when is_list(entries) <- decode(body) do
          forward = trim(entries)
          write(forward)
          forget()
          {:ok, map_size(forward)}
        else
          _ -> {:error, :unreadable_list}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp decode(body) when is_list(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_body), do: :error

  # Only the two columns laev asks about, and only entries that have both ends.
  # 39,577 rows of fifteen ids each become 8,294 of two.
  defp trim(entries) do
    for %{"mal_id" => mal, "themoviedb_id" => tmdb} = row <- entries,
        is_integer(mal),
        is_map(tmdb),
        pair = pair_for(tmdb, season_of(row)),
        into: %{} do
      {Integer.to_string(mal), pair}
    end
  end

  defp pair_for(%{"tv" => id}, season), do: with(n when is_integer(n) <- one_id(id), do: ["tv", n, season])
  defp pair_for(%{"movie" => id}, _season), do: with(n when is_integer(n) <- one_id(id), do: ["movie", n])
  defp pair_for(_tmdb, _season), do: nil

  # A sixth of the rows write the id as a one-element list — `{"movie": [128]}`
  # rather than `{"movie": 128}`, and thirty list two. Either way the first is
  # the title; reading only the bare integers lost 1,332 anime, Spirited Away
  # among them.
  defp one_id(id) when is_integer(id), do: id
  defp one_id([id | _]) when is_integer(id), do: id
  defp one_id(_id), do: nil

  # Which TMDB season this MAL entry is. The row says so outright — that single
  # number is the whole reason for using this list instead of matching titles.
  # Season 1 when it's silent, which is what a one-season show is.
  defp season_of(%{"season" => %{"tmdb" => season}}) when is_integer(season) and season > 0, do: season
  defp season_of(_row), do: 1

  # ── the cached map, read once per run ─────────────────────────────

  defp load do
    case :persistent_term.get({__MODULE__, :map}, nil) do
      nil ->
        built = build()
        :persistent_term.put({__MODULE__, :map}, built)
        built

      built ->
        built
    end
  end

  @doc "Drop the in-memory copy, so the next lookup reads the file again."
  def forget, do: :persistent_term.erase({__MODULE__, :map})

  defp build do
    forward = read()

    tv =
      for {mal, ["tv", id, season]} <- forward,
          into: %{},
          do: {"#{id}-#{season || 1}", String.to_integer(mal)}

    movie = for {mal, ["movie", id]} <- forward, into: %{}, do: {Integer.to_string(id), String.to_integer(mal)}

    %{
      forward: forward,
      tv: tv,
      movie: movie,
      tv_ids: for({_m, ["tv", id, _s]} <- forward, into: MapSet.new(), do: id),
      movie_ids: for({_m, ["movie", id]} <- forward, into: MapSet.new(), do: id)
    }
  end

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"ids" => ids}} when is_map(ids) <- Jason.decode(body) do
      ids
    else
      _ -> %{}
    end
  end

  defp write(forward) do
    File.write(path(), Jason.encode!(%{"fetched_at" => System.os_time(:second), "ids" => forward}))
  rescue
    _ -> :ok
  end

  defp fresh? do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"fetched_at" => at}} <- Jason.decode(body) do
      System.os_time(:second) - at < @max_age
    else
      _ -> false
    end
  end

  defp path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    File.mkdir_p!(dir)
    Path.join(dir, @cache)
  end
end
