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
  @probe_concurrency 2

  @doc """
  Resolve on the first provider that can play the magnet. RD's error is
  returned when everything fails (it's the primary; its reasons are the
  most specific). `{:ok, stream}` — stream carries `:provider`.
  """
  def resolve_magnet(magnet, opts \\ []) do
    cond do
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
    |> Task.async_stream(fn {source, stream} -> {source, with_tracks(stream)} end,
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
  """
  def probe_sources(indexed_sources, opts \\ []) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])

    indexed_sources
    |> Task.async_stream(
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
    resolve_opts = [patience: 5] ++ Keyword.take(opts, [:episode, :season])
    do_resolve_best(sources, notify, resolve_opts, [])
  end

  defp do_resolve_best([], _notify, _resolve_opts, skipped),
    do: {:error, {:all_failed, Enum.reverse(skipped)}}

  defp do_resolve_best([source | rest], notify, resolve_opts, skipped) do
    notify.({:trying, source.name})

    case probe_resolve(source, resolve_opts) do
      {:ok, stream} ->
        {:ok, stream, source, Enum.reverse(skipped)}

      {:error, reason} ->
        reason = if match?({:rd, 451, _}, reason), do: :infringing, else: reason
        notify.({:skipped, source.name, reason})
        do_resolve_best(rest, notify, resolve_opts, [{source.name, reason} | skipped])
    end
  end
end
