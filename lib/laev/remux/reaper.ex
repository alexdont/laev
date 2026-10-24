defmodule Laev.Remux.Reaper do
  @moduledoc """
  Stops conversions nobody is watching.

  A remux worker keeps ffmpeg running for its full two hours whatever becomes of
  whoever asked for it, and a re-encode takes a core the whole time. A closed
  tab, or a video that never became ready, left it burning — four of those put a
  host at a load average near 150.

  So whatever serves the segments calls `Laev.Remux.touch/1` as it does, and
  every minute the conversions nobody has asked for in ten are stopped. What
  they finished stays on disk: the segments are a cache, and coming back to the
  film reuses them.

  A conversion is never cut short for being young — the clock starts the first
  time the sweep sees it, not when it was started — so a slow first segment
  does not count as nobody watching.
  """
  use GenServer

  @table __MODULE__
  @every :timer.minutes(1)
  @idle_seconds 10 * 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "A conversion was just asked for. Safe to call before the reaper starts."
  def touch(id) when is_binary(id) do
    :ets.insert(@table, {id, System.monotonic_time(:second)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def touch(_id), do: :ok

  @doc false
  def last_touch(id) do
    case :ets.lookup(@table, id) do
      [{^id, at}] -> at
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set])
    every = Keyword.get(opts, :every, @every)
    idle = Keyword.get(opts, :idle_seconds, @idle_seconds)
    schedule(every)
    {:ok, %{every: every, idle: idle}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.idle)
    schedule(state.every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def sweep(idle_seconds \\ @idle_seconds) do
    now = System.monotonic_time(:second)

    for id <- Laev.Remux.running() do
      case :ets.lookup(@table, id) do
        # First time seen: the clock starts now, so a conversion that has only
        # just begun is never taken for an abandoned one.
        [] -> :ets.insert(@table, {id, now})
        [{_id, at}] when now - at > idle_seconds -> stop(id)
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp stop(id) do
    Laev.Remux.stop(id)
    :ets.delete(@table, id)
  end

  defp schedule(every), do: Process.send_after(self(), :sweep, every)
end
