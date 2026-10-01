defmodule Laev.Seasons do
  @moduledoc """
  How many episodes of a season have actually aired.

  Written whenever laev asks TMDB about a season — which it does every time you
  pick or play an episode — and read where asking is not an option: the home
  screen, which never fetches, and which was offering episode 10 of a
  nine-episode season on the strength of adding one and hoping.

  Small and disposable. A wrong answer here only costs the Up Next row, so an
  unknown season is treated as "maybe", and the file can be deleted without
  consequence.
  """

  @filename "seasons.json"

  @doc "Remember how many episodes of this season are out."
  def put(tv_id, season, aired) when is_integer(tv_id) and is_integer(aired) do
    write(Map.put(read(), key(tv_id, season), %{"aired" => aired, "at" => System.os_time(:second)}))
    :ok
  rescue
    _ -> :ok
  end

  def put(_tv_id, _season, _aired), do: :ok

  @doc """
  How many of a show's seasons have actually aired — TMDB lists the announced
  ones too, and they are not something you can be behind on.

  Written whenever a screen fetches a show's details, and read by the home
  screen, which fetches nothing: it is how the count of shows to finish can
  leave out the ones you are merely waiting on.
  """
  def put_aired_seasons(tv_id, count), do: put_aired_seasons_many(%{tv_id => count})

  @doc """
  The same for many shows at once, in one write.

  Which is the only safe way to do it from concurrent work: every writer here
  reads the whole file, changes a key and writes it back, so eight tasks saving
  one show each keep one of the eight. The screen that fetches a page of shows
  collects them and saves once.
  """
  def put_aired_seasons_many(counts) when is_map(counts) do
    entries =
      for {tv_id, count} <- counts, is_integer(tv_id), is_integer(count), into: %{} do
        {"tv-#{tv_id}-seasons", %{"aired" => count, "at" => System.os_time(:second)}}
      end

    if entries != %{}, do: write(Map.merge(read(), entries))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Aired seasons for a show, or nil when laev has never looked."
  def aired_seasons(tv_id) do
    case read()["tv-#{tv_id}-seasons"] do
      %{"aired" => count} when is_integer(count) -> count
      _ -> nil
    end
  end

  @doc "Episodes aired in this season, or nil when laev has never looked."
  def aired(tv_id, season) do
    case read()[key(tv_id, season)] do
      %{"aired" => aired} when is_integer(aired) -> aired
      _ -> nil
    end
  end

  defp key(tv_id, season), do: "tv-#{tv_id}-s#{season || 0}"

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp write(map), do: File.write(path(), Jason.encode!(map))

  defp path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    File.mkdir_p(dir)
    Path.join(dir, @filename)
  end
end
