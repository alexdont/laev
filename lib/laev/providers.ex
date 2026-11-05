defmodule Laev.Providers do
  @moduledoc """
  Multi-debrid orchestration: one resolve/probe interface over every
  configured provider (Real-Debrid first — deepest cache — then TorBox).

  A source is playable if ANY provider can serve it. The interplay with the
  DMCA blocklist matters: an RD 451 no longer buries a source — TorBox gets
  a shot first, and hashes already on the blocklist (including ones recorded
  before TorBox existed) are still probed on TorBox, RD skipped. A hash is
  only blocklisted when no configured provider can play it.
  """

  alias Laev.{Blocklist, RD, Torbox, Tracks}

  def any_configured?, do: RD.configured?() or Torbox.configured?()

  # How many sources are probed at once. Left at 2: raising it looked obvious
  # but measured worse as often as better — probe time is dominated by how
  # long a given torrent takes to resolve on the provider, and that varies by
  # an order of magnitude between sources, so the setting barely shows through
  # the noise. Configurable so that can be re-measured rather than re-argued.
  # Four at a time rather than two: a page of releases is checked in half the
  # waves, and the work is almost all waiting on somebody else's server.
  @probe_concurrency 4

  # How long the best source gets to answer before a second is started beside
  # it.
  #
  # Measured across nine titles: eight resolved on the first attempt, between
  # 516ms and 2444ms. So the common play never hedges at all and costs one
  # resolve — six Real-Debrid requests against the forty-eight a page of eight
  # costs, and about three times faster, because a page is only as quick as its
  # slowest member.
  #
  # The tenth title is why this is not simply sequential: its first two sources
  # failed in 1.5s and 1.3s and its third hung for 11.8s, which serially is
  # fifteen seconds of nothing. Hedging starts the second attempt at 2.5s
  # instead of waiting for that.
  @hedge_after 2_500

  # And never more than this many at once, which is the whole point: a page of
  # eight leaves up to eight torrents in somebody's debrid account for one film
  # watched.
  @max_in_flight 3

  @doc """
  Resolve on the first provider that can play the magnet. RD's error is
  returned when everything fails (it's the primary; its reasons are the
  most specific). `{:ok, stream}` — stream carries `:provider`.
  """
  def resolve_magnet(magnet, opts \\ []) do
    cond do
      # A lapsed subscription answers every source the same way. Asking fifty
      # times is fifty waits for a reason already known — so a known-expired
      # account short-circuits, and only a *known* one: an unchecked or
      # unreachable account still gets to try.
      expired = Laev.Account.blocked() ->
        {:error, expired}

      RD.configured?() ->
        case RD.resolve_magnet(magnet, opts) do
          {:ok, stream} -> {:ok, Map.put_new(stream, :provider, :rd)}
          {:error, rd_reason} -> torbox_rescue(magnet, opts, rd_reason)
        end

      Torbox.configured?() ->
        Torbox.resolve_magnet(magnet, opts)

      true ->
        {:error, :no_provider_configured}
    end
  end

  defp torbox_rescue(magnet, opts, rd_reason) do
    with true <- Torbox.configured?(),
         {:ok, stream} <- Torbox.resolve_magnet(magnet, opts) do
      {:ok, stream}
    else
      _ -> {:error, rd_reason}
    end
  end

  # Resolve for probing, blocklist-aware: known-DMCA hashes skip RD (it
  # would 451 again) but still get tried on TorBox. New 451s only enter the
  # blocklist when TorBox can't play them either.
  defp probe_resolve(source, resolve_opts) do
    cond do
      Blocklist.blocked?(source.hash) and Torbox.configured?() ->
        case Torbox.resolve_magnet(source.magnet, resolve_opts) do
          {:ok, stream} -> {:ok, stream}
          {:error, _} -> {:error, :known_blocked}
        end

      Blocklist.blocked?(source.hash) ->
        {:error, :known_blocked}

      true ->
        case resolve_magnet(source.magnet, resolve_opts) do
          {:ok, stream} ->
            {:ok, stream}

          {:error, {:rd, 451, _}} = err ->
            Blocklist.block(source.hash)
            err

          other ->
            other
        end
    end
  end

  @doc """
  Attach real audio/subtitle languages to probed streams, so the picker can
  show them and ranking can trust them over release-name guesses.

  Done as one concurrent batch rather than inside each probe: RD reads the
  container server-side the first time it is asked about a stream, which
  costs about 1.8s — paid per source while probing (two at a time) that is
  most of a minute for a full page, and paid all at once here it is one
  round trip. Best-effort throughout: a stream whose lookup fails simply has
  no `:tracks` and its row falls back to what the release name says.
  """
  def attach_tracks(playable) when is_list(playable) do
    playable
    |> Laev.Scope.async_stream(fn {source, stream} -> {source, with_tracks(stream)} end,
      max_concurrency: 8,
      ordered: true,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(playable)
    |> Enum.map(fn
      {{:ok, enriched}, _original} -> enriched
      {_failed, original} -> original
    end)
  end

  # TorBox streams have no equivalent endpoint.
  defp with_tracks(%{provider: :rd, id: id} = stream) when is_binary(id) do
    case RD.media_info(id) do
      {:ok, body} -> Map.put(stream, :tracks, Tracks.from_media_info(body))
      {:error, _} -> stream
    end
  end

  defp with_tracks(stream), do: stream

  @doc """
  Concurrently resolve a batch of `{source, index}` tuples across all
  providers, reporting each outcome through `opts[:notify]` as
  `{:result, index, source, {:ok, stream} | {:error, reason}}`.

  Pass `ctx:` — a map with `:episode` and optionally `:tmdb_episode`, `:season`
  and `:anime` — and two things happen that cannot happen without it: each
  release is asked for the episode number *it* uses, so a pack numbered 13..25
  is asked for 15 rather than 3; and what comes back is checked against what was
  wanted, so a file that merely plays is not mistaken for the right one.
  """
  def probe_sources(indexed_sources, opts \\ []) do
    case Keyword.get(opts, :ctx) do
      %{} = ctx -> probe_by_numbering(indexed_sources, ctx, opts)
      _ -> probe_batch(indexed_sources, opts)
    end
  end

  # Releases are not all numbered alike, so they are probed in groups by the
  # number each of them uses.
  defp probe_by_numbering(indexed_sources, ctx, opts) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)

    confirming = fn
      {:result, index, source, result} ->
        notify.({:result, index, source, Laev.Episodes.confirm(result, source, ctx)})

      other ->
        notify.(other)
    end

    for {episode, group} <- Laev.Episodes.group_by_numbering(indexed_sources, ctx) do
      group
      |> probe_batch(
        opts
        |> Keyword.drop([:ctx])
        |> Keyword.put(:episode, episode)
        |> Keyword.put(:notify, confirming)
      )
    end

    :ok
  end

  defp probe_batch(indexed_sources, opts) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])

    indexed_sources
    |> Laev.Scope.async_stream(
      fn {source, index} ->
        notify.({:result, index, source, probe_resolve(source, resolve_opts)})
      end,
      max_concurrency: Keyword.get(opts, :concurrency, @probe_concurrency),
      ordered: false,
      timeout: 120_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  @doc """
  Try a ranked list of sources and return the first that plays on any
  provider. Reports `{:trying, name}` / `{:skipped, name, reason}` through
  `opts[:notify]`. Returns `{:ok, stream, source, skipped}` or
  `{:error, {:all_failed, skipped}}`.
  """
  def resolve_best(sources, opts \\ []) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    hedge = Keyword.get(opts, :hedge_after, @hedge_after)
    in_flight = Keyword.get(opts, :max_in_flight, @max_in_flight)
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])
    # The prober is an argument so the racing above it can be tested without a
    # debrid account and without waiting on anybody's network.
    resolver = Keyword.get(opts, :resolver, &probe_resolve/2)

    sources
    |> Enum.with_index()
    |> race([], notify, {resolver, resolve_opts}, hedge, in_flight, [])
  end

  # Nothing left to try and nothing still trying.
  defp race([], [], _notify, _probe, _hedge, _in_flight, skipped),
    do: {:error, {:all_failed, Enum.reverse(skipped)}}

  defp race(queue, flight, notify, probe, hedge, in_flight, skipped) do
    # Always something in the air: the best source not yet tried goes first.
    {queue, flight} = launch(queue, flight, notify, probe, in_flight)

    case Task.yield_many(Enum.map(flight, &elem(&1, 2)), hedge) do
      answers when is_list(answers) ->
        {done, waiting} = Enum.split_with(answers, fn {_task, answer} -> answer != nil end)

        finished =
          for {task, answer} <- done,
              {index, source, ^task} <- flight,
              do: {index, source, unwrap(answer)}

        still = for {task, nil} <- waiting, {index, source, ^task} <- flight, do: {index, source, task}

        case winner(finished) do
          {index, source, stream} ->
            # The losers are abandoned rather than waited for. A probe already
            # in flight will finish on Real-Debrid's side whatever we do, so
            # there is nothing to gain by watching it.
            for {_i, _s, task} <- still, do: Task.shutdown(task, :brutal_kill)
            _ = index
            {:ok, stream, source, Enum.reverse(skipped)}

          nil ->
            skipped = Enum.reduce(failures(finished), skipped, fn {name, reason}, acc ->
              notify.({:skipped, name, reason})
              [{name, reason} | acc]
            end)

            # Nobody has answered inside the window, so a second source is
            # started beside the first rather than behind it — see @hedge_after.
            race(queue, still, notify, probe, hedge, in_flight, skipped)
        end
    end
  end

  defp launch(queue, flight, notify, probe, in_flight) do
    cond do
      queue != [] and flight == [] ->
        [{source, index} | rest] = queue
        notify.({:trying, source.name})
        {rest, [start(index, source, probe)]}

      # One more alongside what is already running, while the cap allows.
      queue != [] and length(flight) < in_flight ->
        [{source, index} | rest] = queue
        notify.({:hedging, source.name})
        {rest, flight ++ [start(index, source, probe)]}

      true ->
        {queue, flight}
    end
  end

  defp start(index, source, {resolver, resolve_opts}),
    do: {index, source, Laev.Scope.async(fn -> resolver.(source, resolve_opts) end)}

  defp unwrap({:ok, result}), do: result
  defp unwrap({:exit, reason}), do: {:error, {:probe_crashed, reason}}

  # The best-ranked of whatever has actually answered. While nothing is hedged —
  # which is every play where the first source answers in time — that is the
  # first source, and the pick is exactly what probing the whole page would have
  # chosen. Once hedging starts it can be a lower-ranked release: the leader was
  # slow, and a good source now beats a marginally better one later.
  defp winner(finished) do
    finished
    |> Enum.filter(fn {_index, _source, result} -> match?({:ok, _}, result) end)
    |> Enum.min_by(fn {index, _source, _result} -> index end, fn -> nil end)
    |> case do
      {index, source, {:ok, stream}} -> {index, source, stream}
      _ -> nil
    end
  end

  defp failures(finished) do
    for {_index, source, {:error, reason}} <- finished do
      {source.name, if(match?({:rd, 451, _}, reason), do: :infringing, else: reason)}
    end
  end
end
