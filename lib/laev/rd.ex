defmodule Laev.RD do
  @moduledoc """
  Real-Debrid REST API client.

  Core flow: `resolve_magnet/1` takes a magnet link and returns a direct
  HTTPS stream URL, going through addMagnet -> selectFiles -> unrestrict.
  """

  alias Laev.FilePick
  alias Laev.RD.{Cache, Ledger}

  @base "https://api.real-debrid.com/rest/1.0"

  def configured?, do: token() not in [nil, ""]

  def add_magnet(magnet) do
    post("/torrents/addMagnet", magnet: magnet)
  end

  def torrent_info(id) do
    case Req.get(req(), url: "/torrents/info/#{id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> error(other)
    end
  end

  def select_files(id, file_ids) do
    case Req.post(req(), url: "/torrents/selectFiles/#{id}", form: [files: Enum.join(file_ids, ",")]) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> error(other)
    end
  end

  def unrestrict(link) do
    post("/unrestrict/link", link: link)
  end

  def delete_torrent(id) do
    Req.delete(req(), url: "/torrents/delete/#{id}")
    :ok
  end

  @doc """
  The account's torrents, newest first, as the provider returns them. Raw
  because the sweep judges them on `status`, `added` and `id` — `library/1`
  answers the different question of what is playable right now.
  """
  def torrents(opts \\ []) do
    case Req.get(req(), url: "/torrents", params: [limit: Keyword.get(opts, :limit, 100)]) do
      {:ok, %{status: 200, body: list}} when is_list(list) -> {:ok, list}
      other -> error(other)
    end
  end

  @doc """
  Torrents already downloaded in the user's account whose filename contains
  every word of `query` — instant, guaranteed-playable sources (the same trick
  DMM-style Stremio addons use to surface "definite" streams).
  """
  def library(query) do
    case Req.get(req(), url: "/torrents", params: [limit: 100]) do
      {:ok, %{status: 200, body: torrents}} when is_list(torrents) ->
        tokens = tokenize(query)

        torrents
        |> Enum.filter(fn t ->
          t["status"] == "downloaded" and matches_tokens?(t["filename"], tokens)
        end)
        |> Enum.map(fn t ->
          %{name: t["filename"], hash: String.downcase(t["hash"] || ""), size: t["bytes"] || 0}
        end)
        |> Enum.reject(&(&1.hash == ""))

      _ ->
        []
    end
  end

  defp tokenize(str) do
    str |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp matches_tokens?(filename, tokens) do
    words = tokenize(filename || "")
    tokens != [] and Enum.all?(tokens, &(&1 in words))
  end

  @doc """
  Magnet in, playable URL out.

  Returns `{:ok, %{url: url, filename: name, filesize: bytes}}` when the
  torrent is cached on RD (near-instant), or `{:error, {:not_cached, status, progress}}`
  when RD has started downloading it server-side (it will be available later),
  or `{:error, reason}` for API failures.
  """
  def resolve_magnet(magnet, opts \\ []) do
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)
    hash = hash_of(magnet)

    # Five calls, or none. What was resolved before is remembered per episode
    # and checked before it is trusted — see `Laev.RD.Cache`.
    case lookup(hash, season, episode, opts) do
      {:ok, stream} -> {:ok, stream}
      :miss -> fresh_resolve(magnet, hash, season, episode, opts)
    end
  end

  defp lookup(nil, _season, _episode, _opts), do: :miss

  defp lookup(hash, season, episode, opts) do
    if Keyword.get(opts, :cache, true), do: Cache.get(hash, season, episode), else: :miss
  end

  defp fresh_resolve(magnet, hash, season, episode, opts) do
    patience = Keyword.get(opts, :patience, 12)

    with {:ok, %{"id" => id}} <- add_magnet(magnet) do
      # Adding a magnet creates a torrent in the account whatever happens next,
      # and a probe that loses a hedged race is killed before it can tidy up.
      # The claim is what gets it deleted anyway — see `Laev.RD.Ledger`.
      Ledger.claim(id)

      result =
        with {:ok, info} <- await_file_list(id),
             {:ok, file} <- FilePick.choose(info["files"], episode, season),
             :ok <- select_files(id, [file["id"]]),
             {:ok, %{"links" => [link | _]}} <- await_links(id, patience),
             {:ok, unrestricted} <- unrestrict(link) do
          {:ok, stream_from(unrestricted)}
        end

      case result do
        # Successful torrents stay in the account: this one is playing, and the
        # others are on the picker's page, where switching source must not cost
        # a second resolve.
        {:ok, stream} ->
          Ledger.keep(id)
          Cache.put(hash, season, episode, stream)
          {:ok, stream}

        # And the ones that failed (not cached, infringing, no video) go, so
        # they don't pile up.
        {:error, _reason} ->
          delete_torrent(id)
          Ledger.forget(id)
          result
      end
    end
  end

  # The infohash a magnet carries, lowercased — the key the link cache and the
  # blocklist both use. nil for a magnet without one, which simply isn't cached.
  @doc false
  def hash_of(magnet) when is_binary(magnet) do
    case Regex.run(~r/urn:btih:([a-zA-Z0-9]{40})/, magnet) do
      [_, hash] -> String.downcase(hash)
      _ -> nil
    end
  end

  def hash_of(_magnet), do: nil

  defp stream_from(u) do
    %{
      url: u["download"],
      download_url: u["download"],
      filename: u["filename"],
      filesize: u["filesize"],
      id: u["id"],
      streamable: u["streamable"] == 1,
      hls: false
    }
  end

  @doc """
  Download a source on Real-Debrid (for non-cached torrents), fetching only the
  requested episode file — not the whole batch — and reporting progress through
  `opts[:notify]` as `{:progress, percent, status, speed}`. Blocks (polling)
  until RD finishes, then returns `{:ok, stream}`. Instant for cached torrents.

  `opts`: `:episode` (file to select from a batch), `:notify`, `:max_wait_ms`.
  """
  def download_magnet(magnet, opts \\ []) do
    episode = Keyword.get(opts, :episode)
    season = Keyword.get(opts, :season)
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    max_wait = Keyword.get(opts, :max_wait_ms, 20 * 60 * 1000)

    with {:ok, %{"id" => id}} <- add_magnet(magnet),
         {:ok, info} <- await_file_list(id),
         {:ok, file} <- FilePick.choose(info["files"], episode, season),
         :ok <- select_files(id, [file["id"]]) do
      poll_download(id, notify, max_wait, System.monotonic_time(:millisecond))
    end
  end

  defp poll_download(id, notify, max_wait, started) do
    case torrent_info(id) do
      {:ok, %{"status" => "downloaded", "links" => [link | _]}} ->
        with {:ok, unrestricted} <- unrestrict(link), do: {:ok, stream_from(unrestricted)}

      {:ok, %{"status" => status} = info} when status in ~w(downloading queued compressing uploading magnet_conversion) ->
        elapsed = System.monotonic_time(:millisecond) - started
        progress = info["progress"] || 0
        seeders = info["seeders"] || 0

        cond do
          elapsed > max_wait ->
            delete_torrent(id)
            {:error, {:download_timeout, progress}}

          # No seeders and no progress after a grace period: the torrent is dead,
          # RD will just sit at 0% then flip to "error". Bail early with a clear reason.
          seeders == 0 and progress == 0 and elapsed > 25_000 ->
            delete_torrent(id)
            {:error, :no_seeders}

          true ->
            notify.({:progress, progress, status, info["speed"] || 0})
            Process.sleep(2000)
            poll_download(id, notify, max_wait, started)
        end

      {:ok, %{"status" => "waiting_files_selection"}} ->
        Process.sleep(1000)
        poll_download(id, notify, max_wait, started)

      # Terminal failure. RD marks a torrent "error"/"dead" when it can't fetch
      # it — almost always because nothing is seeding it. Say so plainly.
      {:ok, %{"status" => status} = info} ->
        delete_torrent(id)
        if status in ~w(error dead) and (info["seeders"] || 0) == 0,
          do: {:error, :no_seeders},
          else: {:error, {:torrent_status, status}}

      error ->
        error
    end
  end

  @doc """
  Media details for an unrestricted download id (`stream.id`): RD probes
  the container server-side and lists every audio/subtitle track with its
  language — one ~300ms call, not a byte of the file fetched locally.

  Runs inside source probing, where a slow answer costs more than a
  missing one: no retries, short timeout, caller treats errors as "unknown".
  """
  def media_info(download_id) do
    case Req.get(req(),
           url: "/streaming/mediaInfos/#{download_id}",
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      other -> error(other)
    end
  end

  @doc """
  HLS transcode URL (AAC audio) for an unrestricted download id.

  This is the fix for releases whose audio the browser can't decode
  (DTS, TrueHD, AC3): RD re-muxes to HLS and transcodes audio to AAC.
  """
  def transcode_hls(download_id) do
    case Req.get(req(), url: "/streaming/transcode/#{download_id}") do
      {:ok, %{status: 200, body: %{"apple" => %{"full" => url}}}} -> {:ok, url}
      {:ok, %{status: 200, body: body}} -> {:error, {:no_hls_variant, Map.keys(body)}}
      other -> error(other)
    end
  end

  # RD needs a moment after addMagnet before the file list is available.
  # Waiting on the provider: the first look is immediate and what follows backs
  # off, rather than asking once a second for the whole window.
  #
  # The window is exactly what it was — a source given ten seconds to come up
  # still gets ten seconds — and the cost of waiting it out drops from ten
  # requests to seven. Counted, not estimated: `poll_plan/1` is the schedule,
  # and the test counts it rather than trusting this comment.
  #
  # It is a trade, not a free win. Fewer looks means a coarser answer later in
  # the window: a torrent ready at 300ms is found at 500ms where a flat second
  # found it at 1s, and one ready at 600ms is found at 1.5s where a flat second
  # found it at 1s. Resolving waits seconds on somebody else's server either
  # way, and the request this saves is the thing being asked for.
  #
  # The saving lands where the waiting actually happens: on the sources that
  # never come up, which are polled for the whole window before laev gives up.
  # The five-second window the probes use costs what it always did.
  @first_wait 500
  @growth 2.0
  @longest_wait 3_000
  @file_list_window 10_000

  defp await_file_list(id), do: await_file_list(id, deadline(@file_list_window), @first_wait)

  defp await_file_list(id, deadline, wait) do
    case torrent_info(id) do
      {:ok, %{"status" => "waiting_files_selection"} = info} ->
        {:ok, info}

      {:ok, %{"status" => "magnet_error"}} ->
        {:error, :magnet_error}

      # Files already selected: this magnet was resolved before. Real-Debrid
      # does not dedupe by hash — adding one twice answers with a second id —
      # so this is a torrent laev selected on an earlier attempt, not a
      # duplicate the provider folded together.
      {:ok, %{"status" => status} = info} when status in ~w(downloaded downloading queued) ->
        {:ok, info}

      {:ok, _info} ->
        if sleep_within(deadline, wait),
          do: await_file_list(id, deadline, longer(wait)),
          else: {:error, :timeout_waiting_for_files}

      error ->
        error
    end
  end

  # Cached torrents flip to "downloaded" within a couple of seconds. `patience`
  # stays what it always meant in wall clock — it was that many one-second
  # attempts — so nothing is given up on sooner than it used to be.
  defp await_links(id, patience), do: await_links(id, deadline(patience * 1_000), @first_wait)

  defp await_links(id, deadline, wait) do
    case torrent_info(id) do
      {:ok, %{"status" => "downloaded"} = info} ->
        {:ok, info}

      {:ok, %{"status" => status, "progress" => progress}} when status in ~w(downloading queued) ->
        if sleep_within(deadline, wait),
          do: await_links(id, deadline, longer(wait)),
          else: {:error, {:not_cached, status, progress}}

      {:ok, %{"status" => status}} ->
        {:error, {:torrent_status, status}}

      error ->
        error
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # Sleep for `wait`, or for whatever is left of the window, and say whether
  # there is still time to ask again.
  defp sleep_within(deadline, wait) do
    case min(wait, deadline - System.monotonic_time(:millisecond)) do
      ms when ms > 0 ->
        Process.sleep(ms)
        true

      _ ->
        false
    end
  end

  defp longer(wait), do: min(round(wait * @growth), @longest_wait)

  @doc """
  The sleeps the backoff would take to fill a window of `window_ms`, in order.
  Here so the cost of waiting can be counted in a test rather than argued
  about: the same first wait and the same growth rule the polling uses.
  """
  def poll_plan(window_ms) do
    Stream.unfold({@first_wait, window_ms}, fn
      {_wait, left} when left <= 0 ->
        nil

      {wait, left} ->
        step = min(wait, left)
        {step, {longer(wait), left - step}}
    end)
    |> Enum.to_list()
  end

  defp post(path, form) do
    case Req.post(req(), url: path, form: form) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      other -> error(other)
    end
  end

  defp error({:ok, %{status: status, body: %{"error" => error}}}), do: {:error, {:rd, status, error}}
  defp error({:ok, %{status: status}}), do: {:error, {:rd, status}}
  defp error({:error, exception}), do: {:error, exception}

  defp req do
    # :transient retries 408/429/5xx with exponential backoff, honoring
    # RD's Retry-After header — important when probing sources concurrently.
    # Retries are logged at debug only: 429s are routine while probing and
    # the warnings would drown the CLI's own progress output.
    Req.new(
      base_url: @base,
      auth: {:bearer, token()},
      retry: :transient,
      max_retries: 6,
      retry_log_level: :debug,
      receive_timeout: 30_000
    )
  end

  defp token, do: Laev.Scope.get(:rd_token)
end
