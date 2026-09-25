defmodule Laev.Quality do
  @moduledoc """
  What is actually out there for a title, before you commit to hunting through it.

  A film in cinemas has forty sources and every one of them is a phone camera
  pointed at a screen; the same film two months later has WEB-DLs. The list
  looks identical from the outside, so the only way to tell used to be to pick
  the title, wait through a probe, and read the release names.

  This asks the indexers once per title and keeps the tally: how many sources,
  the best resolution among the ones that aren't cam rips, and how much of it
  is cam. Enough to answer "worth my time?" and "is it out in HD yet?" without
  resolving anything on the debrid provider — that is the slow part, and none
  of it is needed to count what exists.

  Nothing is asked for a title you don't look at. The picker reports which row
  the cursor is on and only that one is fetched, cached on disk for six hours —
  long enough to be instant while browsing, short enough that a film's first
  WEB-DL shows up the same day.
  """

  alias Laev.Sources

  @ttl_s 6 * 3600
  @dir "quality"

  # Resolutions worth calling HD, best first.
  @tiers ["2160p", "1080p", "720p"]

  @doc """
  The cached tally for a title, or nil when nothing fresh is on disk. Never
  touches the network — safe to call while rendering a list.
  """
  def cached(type, tmdb_id) do
    path = path(type, tmdb_id)
    cutoff = System.os_time(:second) - @ttl_s

    with {:ok, %{mtime: mtime}} when mtime > cutoff <- File.stat(path, time: :posix),
         {:ok, body} <- File.read(path),
         {:ok, %{"count" => count} = saved} <- Jason.decode(body) do
      %{count: count, best: saved["best"], hd: saved["hd"] || 0, cam: saved["cam"] || 0}
    else
      _ -> nil
    end
  end

  @doc """
  Ask the indexers what exists for a title and remember the answer.

  `titles` is the accept list from `Laev.Sources.release_ok?/4` — the tally is
  only worth anything if the sources counted are actually this title's, which
  for the 2026 "Runner" films is the difference between "cam only" and "4K".
  """
  def fetch(type, tmdb_id, titles, year) do
    [primary | _] = titles
    kind = if type == "tv", do: :tv, else: :movie

    # A film's releases carry its year; a show's carry S03E01 instead, so
    # asking for "Silo 2023" finds a dozen season packs and misses the hundred
    # episode releases. The title filter does the disambiguating either way.
    query =
      case kind do
        :tv -> Sources.query_title(primary)
        :movie -> Enum.join(Enum.reject([Sources.query_title(primary), year], &is_nil/1), " ")
      end

    case Sources.search(query, backend: :apibay) do
      {:ok, found} ->
        tally = found |> Enum.filter(&Sources.release_ok?(&1.name, titles, year, kind)) |> tally()
        write(type, tmdb_id, tally)
        tally

      # An indexer that didn't answer is not the same as a film with nothing
      # out, and caching it as "no sources" for six hours would say so.
      _ ->
        nil
    end
  end

  defp tally(sources) do
    {cam, rest} = Enum.split_with(sources, &(&1.source == "CAM"))

    %{
      count: length(sources),
      best: Enum.find(@tiers, fn tier -> Enum.any?(rest, &(&1.resolution == tier)) end),
      hd: Enum.count(rest, &(&1.resolution in @tiers)),
      cam: length(cam)
    }
  end

  @doc """
  A short label for a list row: what the best thing available is, or that it
  is all cam. nil when there is nothing worth saying.
  """
  def badge(nil), do: nil
  def badge(%{count: 0}), do: "no sources"
  def badge(%{best: nil, cam: cam}) when cam > 0, do: "cam only"
  # One stray "1080p" among eleven cam rips is usually a mislabelled cam rip,
  # and either way the honest summary of that list is not "HD".
  def badge(%{hd: hd, cam: cam}) when cam > hd, do: "mostly cam"
  def badge(%{best: "2160p"}), do: "4K"
  def badge(%{best: best}) when is_binary(best), do: best
  def badge(_tally), do: nil

  @doc "The full line for the preview pane, beside the poster."
  def line(nil), do: nil
  def line(%{count: 0}), do: "nothing on the indexers yet"

  def line(%{count: count, best: best, hd: hd, cam: cam}) do
    parts =
      [
        "#{count} #{if count == 1, do: "source", else: "sources"}",
        best && "best #{best}",
        hd > 0 && "#{hd} HD",
        cam > 0 && "#{cam} cam"
      ]
      |> Enum.reject(&(!&1))
      |> Enum.join(" · ")

    if is_nil(best) and cam > 0, do: parts <> " — nothing but cam rips yet", else: parts
  end

  defp write(type, tmdb_id, tally) do
    File.mkdir_p(dir())
    File.write(path(type, tmdb_id), Jason.encode!(tally))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Drop tallies nobody will read again. They go stale after six hours, so
  anything much older than that is only taking up a directory entry.
  """
  def prune do
    cutoff = System.os_time(:second) - @ttl_s * 4

    case File.ls(dir()) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir(), name),
            {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
            mtime < cutoff do
          File.rm(path)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp path(type, tmdb_id), do: Path.join(dir(), "#{type}-#{tmdb_id}")

  defp dir do
    base = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    Path.join(base, @dir)
  end
end
