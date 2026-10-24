defmodule Laev.Playback do
  @moduledoc """
  Where a stream is played, and how its progress gets back.

  laev grew up launching a player on the machine it runs on, which is the only
  thing a terminal can do. A web interface can do that too — the server and the
  browser are the same computer, for somebody running this at home — but the
  obvious thing for it to do is play the film in the page, and that is what it
  does unless told otherwise.

  So there are three targets and one setting between them:

    * `browser` — the stream goes to a `<video>` in the page. The default
      anywhere but the terminal.
    * `mpv` / `vlc` — the player on the machine, launched as the CLI launches
      it, for anyone who would rather watch in their own player.

  What the browser gets back is a *source*, not a file. Most releases are h265
  in Matroska, which no browser opens, so they are remuxed into HLS on the way
  through — `Laev.Remux` stream-copies them with ffmpeg, which is lossless and
  near-instant for anything already h264, and segments land on disk fast enough
  that seeking works almost at once. Where a release is something a browser can
  read already, the direct link is handed over instead, because remuxing what
  does not need it costs time for nothing.

  Real-Debrid's own transcoder is deliberately not used: it still answers, but
  the URLs it returns have no host in them and its media-info endpoint replies
  503, so what it offers cannot be played. Remuxing locally is both working and
  ours.

  Progress comes back through `progress/3`, which works out what was watched
  and what was skipped the same way the mpv script and the VLC poller do —
  except from the file rather than from memory, since a browser posting every
  few seconds is a different request each time and remembers nothing.
  """

  alias Laev.{Config, Position, Remux, Scope, Stats}

  # What one posting interval of real playback can advance the playhead by.
  # Anything beyond it was a seek: re-watched or skipped, not watched.
  @default_interval 10
  # Under this, you are at the beginning rather than somewhere worth returning
  # to — the same floor the players use.
  @floor_seconds 30

  # A 4K re-encode on software never keeps up with playing and takes every core
  # trying, so above this it is refused rather than attempted.
  @max_encode_height 1080

  # And this many at once, because the host has other people on it.
  @max_encoders 2

  @doc "Where playback should go for whoever is asking: `:browser`, `:mpv` or `:vlc`."
  def target do
    case Config.player() do
      "browser" -> :browser
      "vlc" -> :vlc
      _ -> :mpv
    end
  end

  @doc """
  Start playing, wherever this user's playback goes.

  For a local player this launches it and says so. For the browser it returns
  what the page needs to play the thing: a URL, how it should be read, where to
  start, and any subtitle laev fetched.
  """
  def start(ctx, stream, opts \\ []) do
    case target() do
      :browser -> browser_source(ctx, stream, opts)
      _ -> {:ok, :launched, Laev.Player.play(ctx, stream.url, Keyword.get(opts, :player_args, []))}
    end
  end

  @doc """
  What the page needs to play this stream.

  `{:ok, %{kind: :hls | :direct, url:, resume_at:, …}}`. HLS where the release
  is not something a browser can read, which is most of them.
  """
  def browser_source(ctx, stream, opts \\ []) do
    source =
      cond do
        browser_readable?(stream) ->
          %{kind: :direct, url: stream.url, mime: mime_for(stream.filename), playable: true}

        match?({:ok, _}, remux(stream)) ->
          {:ok, id} = remux(stream)

          %{
            kind: :remux,
            remux_id: id,
            dir: Remux.dir(id),
            url: stream.url,
            mime: "application/vnd.apple.mpegurl",
            playable: true
          }

        true ->
          # Nothing here can make this playable in a page. The link is handed
          # over anyway — it is what an "open in your own player" button needs
          # — but `playable` says plainly that the page should not expect it to
          # work, because the alternative is a black rectangle and no
          # explanation.
          %{
            kind: :direct,
            url: stream.url,
            mime: mime_for(stream.filename),
            playable: false,
            reason: "ffmpeg is not installed, so this release cannot be remuxed for a browser"
          }
      end

    {:ok,
     Map.merge(source, %{
       title: Keyword.get(opts, :title) || stream.filename,
       filename: stream.filename,
       resume_at: Position.saved_position(ctx) || 0,
       subtitle_file: Keyword.get(opts, :subtitle_file),
       # What the page should post back with, so the arithmetic on this side
       # knows what a plausible step looks like.
       progress_interval: Keyword.get(opts, :interval, @default_interval)
     })}
  end

  @doc """
  Which playlist to serve for a remux, asked when serving rather than when
  starting.

  ffmpeg decides between a single playlist and a master with one variant per
  audio track, and it decides it after it has looked at the file — so a name
  captured at the moment the remux was started is a guess, and was the wrong
  one for every release with more than one audio track.
  """
  def playlist(remux_id), do: Remux.entry_playlist(remux_id)

  @doc """
  Wait until there is enough on disk to start playing — `:fast` for the first
  few segments, `:complete` for the whole thing.

  A wait that times out stops the conversion. It used to be left running for its
  full two hours: nobody was going to watch it, and on a re-encode that is a
  core burning for an audience of none.
  """
  def ready(remux_id, mode \\ :fast, timeout \\ 180_000) do
    case Remux.await_ready(remux_id, mode, timeout) do
      :ok ->
        :ok

      other ->
        Remux.stop(remux_id)
        other
    end
  end

  @doc """
  Would playing this release mean re-encoding it here?

  True when the video is not h264, which a browser cannot read — that is the
  expensive path, and the one worth refusing before it starts rather than
  discovering at a load average of 150.
  """
  def heavy?({source, _stream}), do: heavy?(source)
  def heavy?(%{codec: codec}) when is_binary(codec), do: String.downcase(codec) not in ["h264", "avc", "x264"]
  def heavy?(%{}), do: false
  def heavy?(_source), do: false

  @doc """
  Whether this release may be re-encoded now, or why not.

  `:ok`, `{:error, :too_heavy}` for a source above the height worth
  re-encoding on this machine, or `{:error, :busy}` when enough encodes are
  already running. A caller that would rather try than refuse can raise the cap
  or skip the check; the point is that it exists, because the alternative is
  taking the host down for one viewer.

  Options: `max_height` (default #{@max_encode_height}), `max_encoders`
  (default #{@max_encoders}).
  """
  def allowed?(source, opts \\ []) do
    cond do
      not heavy?(source) ->
        :ok

      above_height?(source, Keyword.get(opts, :max_height, @max_encode_height)) ->
        {:error, :too_heavy}

      encoders_running() >= Keyword.get(opts, :max_encoders, @max_encoders) ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  @doc "How many conversions are running right now."
  def encoders_running, do: length(Remux.running())

  defp above_height?({source, _stream}, max), do: above_height?(source, max)

  defp above_height?(%{resolution: resolution}, max) when is_binary(resolution) do
    case Regex.run(~r/(\d{3,4})p/, resolution) do
      [_, height] -> String.to_integer(height) > max
      _ -> String.downcase(resolution) in ["4k", "2160p", "uhd"] and max < 2160
    end
  end

  defp above_height?(_source, _max), do: false

  @doc """
  Any subtitle tracks pulled out of the release, as WebVTT next to the
  segments — a browser needs them as separate files, which is the one thing a
  `<video>` cannot take from the container itself.
  """
  def subtitles(remux_id), do: Remux.subtitles(remux_id)

  @doc """
  Record where the browser's player has got to.

  Stateless on purpose: a browser posts a position every few seconds and each
  post is its own request, so what was watched since last time is worked out
  from what is already written down rather than from anything held in memory.
  The rules are the ones every other player here follows — a position under
  half a minute is the beginning, past 85% is watched, and a jump is skipped
  rather than watched.
  """
  def progress(ctx, position, opts \\ []) when is_number(position) do
    duration = Keyword.get(opts, :duration, 0) |> to_number()
    interval = Keyword.get(opts, :interval, @default_interval)
    budget = interval * 1.5 + 0.5

    played = Position.played(ctx) || %{watched: 0, skipped: 0, reported: nil}
    %{watched: watched, skipped: skipped} = played

    # Where the page last said it was, not where laev would resume from: the
    # resume point is floored to zero for the first half-minute of a film, and
    # measuring against that would read the second post as a thirty-second jump.
    previous = played[:reported] || Position.saved_position(ctx) || 0

    delta = position - previous

    {watched, skipped, earned} =
      cond do
        delta > 0 and delta <= budget -> {watched + delta, skipped, trunc(delta)}
        delta > budget -> {watched, skipped + delta, 0}
        true -> {watched, skipped, 0}
      end

    Position.record(ctx, %{
      position: position,
      duration: duration,
      watched: watched,
      skipped: skipped,
      # Only once the playhead has been in the first half, so a live-ish
      # stream whose duration tracks its position can't read as finished.
      finished: duration > 0 and position >= duration * 0.85 and previous < duration * 0.85,
      floor: @floor_seconds,
      log_seconds: earned,
      reported: position
    })

    :ok
  end

  @doc """
  The players this user could choose between.

  The browser is offered to a web interface and withheld from the terminal,
  which has no page to play anything in; a local player is offered only where
  it is actually installed, since a list of things that will not work is worse
  than a short list.
  """
  def available(interface \\ :browser) do
    local =
      for {name, binary} <- [{"mpv", "mpv"}, {"vlc", "vlc"}],
          System.find_executable(binary) || macos_bundle(name),
          do: name

    case interface do
      :browser -> ["browser" | local]
      _ -> local
    end
  end

  defp macos_bundle("vlc"), do: File.regular?("/Applications/VLC.app/Contents/MacOS/VLC")
  defp macos_bundle(_name), do: false

  # Keyed by the file rather than by the link: debrid URLs are temporary and
  # differ between resolutions of the same release, and a remux that has
  # already been done should be reused rather than run again.
  defp remux(%{url: url, filename: name} = stream) when is_binary(url) do
    if Remux.available?() do
      Remux.start(url, name || "", key: "#{name}-#{stream[:filesize]}")
    else
      {:error, :no_ffmpeg}
    end
  end

  defp remux(_stream), do: {:error, :no_url}

  # What a browser can read on its own: mp4-family containers, which in
  # practice means h264 and AAC. Everything else goes through HLS.
  defp browser_readable?(%{filename: name}) when is_binary(name) do
    String.ends_with?(String.downcase(name), [".mp4", ".m4v", ".webm"])
  end

  defp browser_readable?(_stream), do: false

  defp mime_for(name) when is_binary(name) do
    cond do
      String.ends_with?(String.downcase(name), ".webm") -> "video/webm"
      String.ends_with?(String.downcase(name), [".mp4", ".m4v"]) -> "video/mp4"
      String.ends_with?(String.downcase(name), ".mkv") -> "video/x-matroska"
      true -> "video/mp4"
    end
  end

  defp mime_for(_name), do: "video/mp4"

  defp to_number(n) when is_number(n), do: n
  defp to_number(_), do: 0

  @doc "How long this user has been watching the thing in front of them."
  def elapsed(ctx) do
    case Position.played(ctx) do
      %{watched: watched} -> Stats.duration(watched)
      _ -> Stats.duration(0)
    end
  end

  @doc false
  def scope_default_player, do: if(Scope.current(), do: "browser", else: "mpv")
end
