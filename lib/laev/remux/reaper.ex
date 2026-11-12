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

  # A conversion that has produced no playlist at all is a different case from
  # one nobody is watching: there is nothing to watch yet. ffmpeg writes its
  # first segment within a few seconds of a working stream, so one that has
  # written nothing after two minutes is not slow, it is stuck — a dead URL, a
  # stream that needs a key, a disk that is full — and waiting out the ten
  # minutes burns a core for nine of them.
  @never_ready_seconds 2 * 60

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

    # A host that serves segments on a slower cadence than a browser does can
    # say so, in its own config, without starting the reaper itself.
    every = opts[:every] || Application.get_env(:laev, :remux_sweep_ms, @every)
    idle = opts[:idle_seconds] || Application.get_env(:laev, :remux_idle_seconds, @idle_seconds)

    never_ready =
      opts[:never_ready_seconds] ||
        Application.get_env(:laev, :remux_never_ready_seconds, @never_ready_seconds)

    schedule(every)
    {:ok, %{every: every, idle: idle, never_ready: never_ready}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.idle, state.never_ready)
    schedule(state.every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def sweep(idle_seconds \\ @idle_seconds, never_ready_seconds \\ @never_ready_seconds) do
    now = System.monotonic_time(:second)

    for id <- Laev.Remux.running() do
      case :ets.lookup(@table, id) do
        # First time seen: the clock starts now, so a conversion that has only
        # just begun is never taken for an abandoned one.
        [] ->
          :ets.insert(@table, {id, now})

        [{_id, at}] ->
          case verdict(now - at, playable?(id), idle_seconds, never_ready_seconds) do
            :stop -> stop(id)
            :keep -> :ok
          end
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # Whether a conversion this old, in this state, is still somebody's. Separate
  # from the sweep because it is the whole policy, and the sweep around it needs
  # a registry and a filesystem to exercise while this needs neither.
  def verdict(age_seconds, playable?, idle_seconds, never_ready_seconds) do
    cond do
      # Nobody has fetched from it inside the window: whoever asked has gone.
      age_seconds > idle_seconds -> :stop
      # Nothing to fetch yet, long after there should have been.
      age_seconds > never_ready_seconds and not playable? -> :stop
      true -> :keep
    end
  end

  # Something a player could actually fetch: a playlist with a segment in it.
  defp playable?(id) do
    case File.read(Path.join(Laev.Remux.dir(id), Laev.Remux.entry_playlist(id))) do
      {:ok, content} -> content =~ "#EXTINF"
      _ -> false
    end
  rescue
    _ -> false
  end

  defp stop(id) do
    Laev.Remux.stop(id)
    :ets.delete(@table, id)
  end

  defp schedule(every), do: Process.send_after(self(), :sweep, every)
end
