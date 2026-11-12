defmodule Laev.Hedge do
  @moduledoc """
  Race a ranked list of candidates, one at a time, starting another beside the
  first when it is slow, and take the best-ranked of whatever answers.

  This is how laev picks a source to play. The list is in rank order, so the
  first candidate is the one wanted; probing all of them would be slower *and*
  dearer, because a page is only as quick as its slowest member. But probing
  them strictly one after another is worse than it sounds: one real page had
  two candidates fail in 1.5s and 1.3s and a third hang for 11.8s — fifteen
  seconds of nothing, served in series.

  So: start the first. If it has not answered within `delay_ms`, start the
  second *beside* it rather than after it, up to `max_parallel` at once. The
  first success wins, and where more than one has answered by then, the
  best-ranked of them does.

  What that trades: on a play where the leader answers in time — most of them —
  the pick is exactly what probing everything would have chosen. Once hedging
  has started it can be a lower-ranked candidate, which is the point: a good
  answer now beats a marginally better one later.

  ## Using it

      Laev.Hedge.run(sources, &resolve/1, delay_ms: 2_500, max_parallel: 3)

  `probe` is called with one candidate and returns `{:ok, result}` or
  `{:error, reason}`; it runs in a task of its own, inside the caller's scope.

      {:ok, result, candidate, %{failed: [...], untried: [...]}}
      {:error, :all_failed, %{failed: [...], untried: []}}

  `untried` is what was never asked, in rank order, so a caller can offer them
  as "more sources" rather than throwing the ranking away and starting again.

  `notify` is called with `{:trying, candidate}` when one is started first,
  `{:hedging, candidate}` when one is started beside a slow one, and
  `{:failed, candidate, reason}` as answers come back — enough to draw a list
  that fills in as it goes.

  A probe has to terminate on its own — of itself, `run/3` waits as long as the
  probes do. `Laev.Providers.resolve_best/2` passes a prober with its own
  patience; anything else should do the same.

  A loser is abandoned, not awaited: `Task.shutdown(task, :brutal_kill)`. Where
  a probe leaves something behind on somebody's account, the caller is
  responsible for cleaning that up — `Laev.RD.Ledger` is laev's answer to it.
  """

  @delay_ms 2_500
  @max_parallel 3

  @type candidate :: term()
  @type outcome :: {:ok, term()} | {:error, term()}
  @type leftovers :: %{failed: [{candidate(), term()}], untried: [candidate()]}

  @doc """
  Race `candidates` through `probe`, best-ranked first. See the module doc.
  """
  @spec run([candidate()], (candidate() -> outcome()), keyword()) ::
          {:ok, term(), candidate(), leftovers()} | {:error, :all_failed, leftovers()}
  def run(candidates, probe, opts \\ []) when is_list(candidates) and is_function(probe, 1) do
    state = %{
      notify: Keyword.get(opts, :notify, fn _event -> :ok end),
      delay: Keyword.get(opts, :delay_ms, @delay_ms),
      max_parallel: Keyword.get(opts, :max_parallel, @max_parallel),
      probe: probe
    }

    race(Enum.with_index(candidates), [], [], state)
  end

  # Nothing left to try and nothing still trying.
  defp race([], [], failed, _state),
    do: {:error, :all_failed, %{failed: Enum.reverse(failed), untried: []}}

  defp race(queue, flight, failed, state) do
    # Always something in the air: the best candidate not yet tried goes first.
    {queue, flight} = launch(queue, flight, state)

    answers = Task.yield_many(Enum.map(flight, &elem(&1, 2)), state.delay)
    {done, waiting} = Enum.split_with(answers, fn {_task, answer} -> answer != nil end)

    finished =
      for {task, answer} <- done,
          {index, candidate, ^task} <- flight,
          do: {index, candidate, unwrap(answer)}

    still = for {task, nil} <- waiting, {index, candidate, ^task} <- flight, do: {index, candidate, task}

    case winner(finished) do
      {_index, candidate, result} ->
        # A probe already in flight will finish wherever it is running whatever
        # this process does, so there is nothing to gain by waiting for it.
        for {_i, _c, task} <- still, do: Task.shutdown(task, :brutal_kill)

        {:ok, result, candidate,
         %{failed: Enum.reverse(failures(finished) ++ failed), untried: untried(queue, still)}}

      nil ->
        failed =
          Enum.reduce(failures(finished), failed, fn {candidate, reason} = failure, acc ->
            state.notify.({:failed, candidate, reason})
            [failure | acc]
          end)

        race(queue, still, failed, state)
    end
  end

  defp launch(queue, flight, state) do
    cond do
      queue != [] and flight == [] ->
        [{candidate, index} | rest] = queue
        state.notify.({:trying, candidate})
        {rest, [start(index, candidate, state)]}

      # One more alongside what is already running, while the cap allows.
      queue != [] and length(flight) < state.max_parallel ->
        [{candidate, index} | rest] = queue
        state.notify.({:hedging, candidate})
        {rest, flight ++ [start(index, candidate, state)]}

      true ->
        {queue, flight}
    end
  end

  # A probe that raises is that candidate failing, not the race coming down:
  # the task is linked to the caller, so without this one bad candidate would
  # take the whole play with it.
  defp start(index, candidate, state) do
    probe = state.probe

    task =
      Laev.Scope.async(fn ->
        try do
          probe.(candidate)
        rescue
          error -> {:error, {:probe_crashed, error}}
        catch
          kind, value -> {:error, {:probe_crashed, {kind, value}}}
        end
      end)

    {index, candidate, task}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:exit, reason}), do: {:error, {:probe_crashed, reason}}

  # The best-ranked of whatever has actually answered — not the first to answer.
  defp winner(finished) do
    finished
    |> Enum.filter(fn {_index, _candidate, result} -> match?({:ok, _}, result) end)
    |> Enum.min_by(fn {index, _candidate, _result} -> index end, fn -> nil end)
    |> case do
      {index, candidate, {:ok, result}} -> {index, candidate, result}
      _ -> nil
    end
  end

  defp failures(finished) do
    for {_index, candidate, {:error, reason}} <- finished, do: {candidate, reason}
  end

  # What was never asked: the queue, and whatever was abandoned mid-flight,
  # back in rank order so a caller can carry on down the list.
  defp untried(queue, still) do
    abandoned = for {index, candidate, _task} <- still, do: {candidate, index}

    (queue ++ abandoned)
    |> Enum.sort_by(fn {_candidate, index} -> index end)
    |> Enum.map(fn {candidate, _index} -> candidate end)
  end
end
