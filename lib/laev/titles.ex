defmodule Laev.Titles do
  @moduledoc """
  What things are called, for the screens that only have an id.

  The stats page used to name titles from the watch history, which worked while
  everything on it had been played here. Import a thousand ratings and most rows
  have no history entry at all — a list of "tv #4607" tells you nothing about
  what you watched.

  So names are written down as laev learns them: the runtime lookup the stats
  page already does returns the title in the same response, and an import brings
  titles with it. Nothing here is ever fetched on its own account.
  """

  @filename "titles.json"

  @doc "The name for a title, or nil."
  def get(type, tmdb_id), do: Map.get(read(), key(type, tmdb_id))

  @doc "Every name laev knows, as `%{\"movie-550\" => \"Fight Club\"}`."
  def all, do: read()

  @doc """
  Remember names, as `%{{type, id} => name}` or `%{\"movie-550\" => name}`.
  Merged over what is already known, so a better name replaces a worse one.
  """
  def put(names) when is_map(names) do
    clean =
      names
      |> Enum.flat_map(fn
        {{type, id}, name} when is_binary(name) and name != "" -> [{key(type, id), name}]
        {key, name} when is_binary(key) and is_binary(name) and name != "" -> [{key, name}]
        _ -> []
      end)
      |> Map.new()

    if clean != %{}, do: write(Map.merge(read(), clean))
    :ok
  rescue
    _ -> :ok
  end

  defp key(type, tmdb_id), do: "#{type}-#{tmdb_id}"

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
