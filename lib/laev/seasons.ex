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
