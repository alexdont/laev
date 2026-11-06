defmodule Laev.RD.Ledger do
  @moduledoc """
  Deletes the torrents nobody kept.

  Resolving a source adds a torrent to the account, and Real-Debrid does not
  dedupe: adding a magnet already there answers with a *new* id, so every probe
  of every source leaves one entry behind for good. Measured on a real account:
  a hundred entries inside twelve hours, five to thirteen per title watched,
  four stuck in `magnet_conversion`, and three still downloading files nobody
  would ever watch — which costs the provider real bandwidth, not an API call.

  A probe that fails already cleans up after itself. A probe that is abandoned
  cannot: `Laev.Providers.resolve_best/2` kills the losers of a hedged race
  where they stand, so the code that would have deleted their torrents never
  runs.

  So a probe claims the torrent it creates and this process watches the
  claimant. A claim released is the probe's to keep — it resolved, and the
  stream is either playing or on the picker's page, where switching to it must
  not need a second resolve. A claimant that dies still holding a claim has
  abandoned it, and it is deleted.

  Claims are written to disk too, under each scope's own directory. A laev
  killed outright takes its monitors with it, so the file is what the next run
  reads to find what the last one left behind — see `Laev.RD.Sweep`.
  """
  use GenServer

  @ledger_file "rd_claims"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Claim torrent `id` for the calling process. Safe to call when the ledger
  isn't running (a library host that starts no supervision tree): then nothing
  is watched and nothing is deleted, exactly as before this existed.
  """
  def claim(id) when is_binary(id) do
    cast({:claim, id, self(), Laev.Scope.current(), Laev.Scope.dir()})
  end

  def claim(_id), do: :ok

  @doc "This torrent is wanted — it resolved. Stop watching it."
  def keep(id) when is_binary(id), do: cast({:release, id})
  def keep(_id), do: :ok

  @doc "This torrent is gone — the caller deleted it. Stop watching it."
  def forget(id) when is_binary(id), do: cast({:release, id})
  def forget(_id), do: :ok

  @doc """
  Ids this scope claimed and never released, as last written to disk. After a
  clean run it is empty; what's in it is what a killed run abandoned.
  """
  def abandoned do
    case File.read(path()) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.uniq()
      _ -> []
    end
  end

  @doc "Drop `ids` from the on-disk ledger (they have been dealt with)."
  def settle(ids) when is_list(ids) do
    case abandoned() -- ids do
      [] -> File.rm(path())
      left -> write(path(), left)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cast(message) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, message)
    :ok
  rescue
    _ -> :ok
  end

  # ── server ────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{claims: %{}, refs: %{}}}

  @impl true
  def handle_cast({:claim, id, pid, scope, dir}, state) do
    if Map.has_key?(state.claims, id) do
      {:noreply, state}
    else
      # Monitoring a process that is already dead still delivers :DOWN, so a
      # probe killed between creating its torrent and this cast being handled
      # is not a torrent lost track of.
      ref = Process.monitor(pid)
      record(dir, id)

      {:noreply,
       %{state | claims: Map.put(state.claims, id, {ref, scope, dir}), refs: Map.put(state.refs, ref, id)}}
    end
  end

  @impl true
  def handle_cast({:release, id}, state) do
    case Map.pop(state.claims, id) do
      {{ref, _scope, dir}, claims} ->
        Process.demonitor(ref, [:flush])
        drop(dir, id)
        {:noreply, %{state | claims: claims, refs: Map.delete(state.refs, ref)}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {id, refs} when is_binary(id) ->
        {{_ref, scope, dir}, claims} = Map.pop(state.claims, id)
        reap(id, scope, dir)
        {:noreply, %{state | claims: claims, refs: refs}}

      {_, refs} ->
        {:noreply, %{state | refs: refs}}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # Off the server: deleting is a network call, and a slow provider must not
  # hold up the next probe's claim.
  defp reap(id, scope, dir) do
    Kernel.spawn(fn ->
      delete(id, scope)
      drop(dir, id)
    end)

    :ok
  end

  defp delete(id, %Laev.Scope{} = scope), do: Laev.Scope.run(scope, fn -> deleter().(id) end)
  defp delete(id, _no_scope), do: deleter().(id)

  # Replaceable so the reaping can be tested without a debrid account.
  defp deleter, do: Application.get_env(:laev, :rd_delete, &Laev.RD.delete_torrent/1)

  # ── the on-disk half ──────────────────────────────────────────────

  defp record(dir, id) do
    file = path(dir)
    File.mkdir_p(Path.dirname(file))
    File.write(file, id <> "\n", [:append])
    :ok
  rescue
    _ -> :ok
  end

  defp drop(dir, id) do
    file = path(dir)

    case File.read(file) do
      {:ok, body} ->
        case body |> String.split("\n", trim: true) |> List.delete(id) do
          [] -> File.rm(file)
          left -> write(file, left)
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp write(file, ids), do: File.write(file, Enum.map_join(ids, "", &(&1 <> "\n")))

  defp path, do: path(Laev.Scope.dir())
  defp path(dir), do: Path.join(dir, @ledger_file)
end
