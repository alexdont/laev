defmodule Laev.Watchlist do
  @moduledoc """
  The user's curated to-watch list — intent, as opposed to `Resume`'s
  automatic history. Titles are pinned/unpinned with ctrl-s from any title
  picker and browsed from the main menu. ETS mirrored to JSON, same pattern
  as `Resume`.

  Entries are plain string-keyed maps:

      %{"type", "tmdb_id", "title", "year", "poster", "added_at"}
  """


  # One table per scope, not one per machine: a named table is shared by every
  # process in the VM, which on a server is every user at once. The name is the
  # scope's, so two people in two requests cannot land in each other's.
  defp table do
    name = :"watchlist_#{Laev.Scope.tag()}"

    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:public, :named_table, :set, read_concurrency: true])
        load()
        name

      _ref ->
        name
    end
  end

  @doc "Make sure this scope's table exists. Asking for it is enough."
  def init, do: table()

  @doc """
  Drop the cache and re-read watchlist.json — for when something other than
  this module rewrote the file (a sync pull).
  """
  def reload do
    init()
    :ets.delete_all_objects(table())
    load()
    :ok
  end

  def key(type, tmdb_id), do: "#{type}:#{tmdb_id}"

  def has?(type, tmdb_id), do: :ets.member(table(), key(type, tmdb_id))

  @doc "All watchlist entries, most recently added first."
  def all do
    table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["added_at"], :desc)
  end

  def count, do: :ets.info(table(), :size)

  @doc "Pin a title (from a TMDB title map: type/id/title/year/poster)."
  def add(title) do
    entry = %{
      "type" => title.type,
      "tmdb_id" => title.id,
      "title" => title.title,
      "year" => title.year,
      "poster" => Map.get(title, :poster),
      "added_at" => System.os_time(:second)
    }

    :ets.insert(table(), {key(title.type, title.id), entry})
    persist()
    :ok
  end

  def remove(type, tmdb_id) do
    :ets.delete(table(), key(type, tmdb_id))
    persist()
    :ok
  end

  @doc "Pin if unpinned, unpin if pinned. Returns :added | :removed."
  def toggle(title) do
    if has?(title.type, title.id) do
      remove(title.type, title.id)
      :removed
    else
      add(title)
      :added
    end
  end

  defp load do
    name = :"watchlist_#{Laev.Scope.tag()}"

    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Enum.each(map, fn {k, v} -> :ets.insert(name, {k, v}) end)
    end

    name
  end

  defp persist do
    data = table() |> :ets.tab2list() |> Map.new()
    File.mkdir_p!(Path.dirname(path()))
    File.write(path(), Jason.encode!(data))
  rescue
    _ -> :ok
  end

  defp path do
    dir = Laev.Scope.dir()
    Path.join(dir, "watchlist.json")
  end

end
