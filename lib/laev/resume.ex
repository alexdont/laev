defmodule Laev.Resume do
  @moduledoc """
  Per-title "continue watching" memory: the last season/episode + the exact
  source (torrent) the user played for each movie/show, so they can resume
  without re-hunting the source list. Held in ETS and mirrored to a JSON file so
  it survives server restarts. Time-within-the-episode is remembered separately,
  client-side (localStorage keyed by the remux id), and resumes automatically.

  Entries are plain string-keyed maps (JSON round-trips cleanly):

      %{"type", "tmdb_id", "season", "episode", "title", "poster_path",
        "source" => %{"name", "magnet", "hash"}, "updated_at"}
  """


  # One table per scope, not one per machine: a named table is shared by every
  # process in the VM, which on a server is every user at once. The name is the
  # scope's, so two people in two requests cannot land in each other's.
  defp table do
    name = :"resume_#{Laev.Scope.tag()}"

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
  Drop the cache and re-read resume.json — for when something other than
  `put/3` rewrote the file (a sync pull). Without this the stale table would
  not only show old history but clobber the synced file on the next persist.
  """
  def reload do
    init()
    :ets.delete_all_objects(table())
    load()
    :ok
  end

  def key(type, tmdb_id), do: "#{type}:#{tmdb_id}"

  @doc "The resume entry for a title, or nil."
  def get(type, tmdb_id) do
    case :ets.lookup(table(), key(type, tmdb_id)) do
      [{_k, entry}] -> entry
      [] -> nil
    end
  end

  @doc "All resume entries, most recently updated first."
  def all do
    table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1["updated_at"], :desc)
  end

  @doc "Record (or update) where the user is in a title."
  def put(type, tmdb_id, entry) do
    :ets.insert(table(), {key(type, tmdb_id), entry})
    persist()
    :ok
  end

  @doc """
  Forget a title's place entirely. The next sync turns the gap into a
  tombstone, so the removal travels to your other devices rather than being
  undone by the first pull.
  """
  def delete(type, tmdb_id) do
    :ets.delete(table(), key(type, tmdb_id))
    persist()
    :ok
  end

  defp load do
    name = :"resume_#{Laev.Scope.tag()}"

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
    # Persistence is best-effort — never let a write failure break playback.
    _ -> :ok
  end

  defp path do
    dir = Laev.Scope.dir()
    Path.join(dir, "resume.json")
  end

end
