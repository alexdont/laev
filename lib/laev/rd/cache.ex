defmodule Laev.RD.Cache do
  @moduledoc """
  Remembers the link a source resolved to, so watching the same thing again
  costs nothing.

  A resolve is five Real-Debrid calls that cannot be fewer: add the magnet,
  read the file list, select the file, wait for the link, unrestrict it. None
  is optional, and the endpoint that once answered "is this hash cached?" for a
  whole page at once (`/torrents/instantAvailability`) now answers
  `403 disabled_endpoint`. So the only calls left to save are the ones made
  twice — and they are made twice often: resuming what you were watching,
  pressing play after stopping, continuing a show on the next evening.

  Cached per scope, keyed by infohash and episode, and good for a day.

  ## Why a stored link is checked before it is trusted

  A link that has expired would reach the player, not this code: the player is
  detached, so by the time it fails laev has handed off and cannot retry. One
  HEAD first settles it — against the download host, not the API, so it counts
  against no rate limit and costs about 380ms.

  It has to be read carefully. Measured against a live link, the same link with
  a nonsense filename, and one with a nonsense id:

      live            -> 200  content-length 1458381821  force-download
      wrong filename  -> 200  content-length 1458381821  force-download
      wrong id        -> 404  content-length 2144        text/html

  So status alone says little — the host serves the file for any filename, as
  long as the id is good. A link is alive when it answers 200 *and* the length
  it reports is the size that was stored. Anything else (a 404's HTML, a
  truncated file, a changed size) misses, and the caller resolves from scratch
  exactly as it did before this existed.
  """

  @dir "rd_links"
  @ttl 24 * 60 * 60
  @head_timeout 5_000

  @doc """
  The stream stored for this source and episode, or nil — no entry, too old,
  or the link no longer serves the file it was stored for.
  """
  def get(hash, season, episode, opts \\ []) do
    # The liveness check is an argument so the rules above can be tested
    # without a debrid account and without a network.
    check = Keyword.get(opts, :alive?, &alive?/2)

    with true <- enabled?(),
         file = path(hash, season, episode),
         {:ok, %{mtime: mtime}} <- File.stat(file, time: :posix),
         true <- fresh?(mtime),
         {:ok, body} <- File.read(file),
         {:ok, %{"url" => url} = stored} <- Jason.decode(body),
         true <- check.(url, stored["filesize"]) do
      {:ok, stream(stored)}
    else
      _ ->
        forget(hash, season, episode)
        :miss
    end
  end

  @doc "Remember this stream for the source and episode it was resolved for."
  def put(hash, season, episode, %{url: url} = stream) when is_binary(url) do
    if enabled?() do
      file = path(hash, season, episode)
      File.mkdir_p(Path.dirname(file))

      File.write(
        file,
        Jason.encode!(%{
          "url" => url,
          "download_url" => stream[:download_url] || url,
          "filename" => stream[:filename],
          "filesize" => stream[:filesize],
          "id" => stream[:id],
          "streamable" => stream[:streamable],
          "hash" => hash
        })
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  def put(_hash, _season, _episode, _stream), do: :ok

  @doc "Drop what was stored for this source and episode."
  def forget(hash, season, episode) do
    File.rm(path(hash, season, episode))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Drop everything stored for this scope."
  def clear do
    dir() |> Path.join("*") |> Path.wildcard() |> Enum.each(&File.rm/1)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Whether a stored link still serves the file it was stored for. Public so the
  reasoning above can be tested against a real link rather than argued about.
  """
  def alive?(url, filesize) when is_binary(url) do
    case Req.head(url, receive_timeout: @head_timeout, retry: false) do
      {:ok, %{status: 200, headers: headers}} -> serves?(headers, filesize)
      _ -> false
    end
  rescue
    _ -> false
  end

  def alive?(_url, _filesize), do: false

  @doc """
  Whether a HEAD's headers say the host is serving a file of `filesize` bytes.
  Public because this, not the status code, is what tells a live link from a
  dead one.
  """
  # No stored size to compare against (an older entry): a 200 is all there is
  # to go on, and the next five calls are the price of being wrong.
  def serves?(_headers, nil), do: true

  def serves?(headers, filesize) when is_integer(filesize) do
    case headers["content-length"] do
      [length | _] -> length == Integer.to_string(filesize)
      _ -> false
    end
  end

  def serves?(_headers, _filesize), do: true

  defp stream(stored) do
    %{
      url: stored["url"],
      download_url: stored["download_url"] || stored["url"],
      filename: stored["filename"],
      filesize: stored["filesize"],
      id: stored["id"],
      streamable: stored["streamable"] == true or stored["streamable"] == 1,
      hls: false,
      cached_link: true
    }
  end

  defp fresh?(mtime), do: System.os_time(:second) - mtime < ttl()

  defp ttl do
    case Laev.Scope.get(:rd_link_ttl) do
      n when is_integer(n) -> n
      s when is_binary(s) -> case Integer.parse(s) do
                               {n, _} -> n
                               _ -> @ttl
                             end
      _ -> @ttl
    end
  end

  # `LAEV_RD_LINK_CACHE=off` for anyone who would rather pay the five calls.
  defp enabled? do
    case Laev.Scope.get(:rd_link_cache) do
      v when is_binary(v) -> String.downcase(String.trim(v)) not in ["off", "false", "no", "0"]
      _ -> true
    end
  end

  defp path(hash, season, episode) do
    Path.join(dir(), "#{String.downcase(to_string(hash))}-#{season || "x"}-#{episode || "x"}.json")
  end

  defp dir, do: Path.join(Laev.Scope.dir(), @dir)
end
