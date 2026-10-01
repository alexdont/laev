defmodule Laev.Holds do
  @moduledoc """
  Shows you have put down, without saying you are done with them.

  MyAnimeList has had this status for years and it is the one laev was missing:
  between "watching" and "finished" sits a large category of things you got four
  episodes into and stopped. Those used to sit at the top of the Watchlist forever,
  crowding out the shows you are actually in the middle of — and marking them
  watched to clear them would be a lie that costs you the watch time.

  A file per held title, which is all this needs to be: the name is the key the
  rest of laev already uses, so it syncs with the same directory machinery as
  positions and played counters, and no cache can go stale against it.

  Anime is not kept here — its status lives on MyAnimeList, which is the list
  that holds anime, and laev reads it from there.
  """

  @dir "holds"

  @doc "True when this title is on hold."
  def held?(type, tmdb_id) do
    File.exists?(path(key(type, tmdb_id)))
  rescue
    _ -> false
  end

  @doc "Put a title on hold, or take it off. Returns :held | :released."
  def toggle(type, tmdb_id) do
    if held?(type, tmdb_id) do
      release(type, tmdb_id)
    else
      hold(type, tmdb_id)
    end
  end

  def hold(type, tmdb_id) do
    File.write(path(key(type, tmdb_id)), to_string(System.os_time(:second)))
    :held
  rescue
    _ -> :held
  end

  def release(type, tmdb_id) do
    File.rm(path(key(type, tmdb_id)))
    :released
  rescue
    _ -> :released
  end

  @doc "Every held title, as `[{type, tmdb_id}]`."
  def all do
    case File.ls(dir()) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          case Regex.run(~r/^(movie|tv)-(\d+)$/, name) do
            [_, type, id] -> [{type, String.to_integer(id)}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc "The same as a set, for a screen that asks about every row it draws."
  def set, do: MapSet.new(all())

  defp key(type, tmdb_id), do: "#{type}-#{tmdb_id}"

  defp path(key), do: Path.join(dir(), key)

  defp dir do
    data = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    dir = Path.join(data, @dir)
    File.mkdir_p!(dir)
    dir
  end
end
