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

  The racing itself is `Laev.Hedge.run/3` — a source that has not answered
  within `hedge_after` has another started beside it, `max_in_flight` at once,
  and the best-ranked of whatever answers wins. This function is what laev
  plays with; anything else that wants the same race over its own candidates
  wants `Laev.Hedge` directly, where the result also says what was never asked.
  """
  def resolve_best(sources, opts \\ []) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])
    # The prober is an argument so the racing above it can be tested without a
    # debrid account and without waiting on anybody's network.
    resolver = Keyword.get(opts, :resolver, &probe_resolve/2)

    hedge_opts = [
      delay_ms: Keyword.get(opts, :hedge_after, @hedge_after),
      max_parallel: Keyword.get(opts, :max_in_flight, @max_in_flight),
      # The source's name is what a picker shows, and `:skipped` is what laev's
      # callers have always been told. Translated here rather than in `Hedge`,
      # which knows nothing about sources.
      notify: fn
        {:trying, source} -> notify.({:trying, source.name})
        {:hedging, source} -> notify.({:hedging, source.name})
        {:failed, source, reason} -> notify.({:skipped, source.name, reason(reason)})
      end
    ]

    case Laev.Hedge.run(sources, &resolver.(&1, resolve_opts), hedge_opts) do
      {:ok, stream, source, %{failed: failed}} -> {:ok, stream, source, skipped(failed)}
      {:error, :all_failed, %{failed: failed}} -> {:error, {:all_failed, skipped(failed)}}
    end
  end

  defp skipped(failed), do: for({source, why} <- failed, do: {source.name, reason(why)})

  # 451 is the provider refusing to touch it, which is worth saying plainly
  # rather than showing somebody an HTTP status.
  defp reason({:rd, 451, _body}), do: :infringing
  defp reason(other), do: other
end
