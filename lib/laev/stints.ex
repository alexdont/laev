defmodule Laev.Stints do
  @moduledoc """
  A tick log of what was watched, when, and for how long — and the sessions it
  folds into.

  The day log beside this one (`watched/<device>.log`) says how many seconds a
  day held and nothing about what filled them; `played/<key>` says how long a
  title has had and nothing about when. Neither can answer "what was I watching
  on Tuesday evening", and a stats window over either has to carry a title's
  whole history in on the strength of one play.

  So every sample laev records writes a line here as well:

      1793000120 movie-27324 5

  Unix seconds, the key the position files already use, and the seconds that
  sample measured. One file per device — the same arrangement the day log
  settled on, and for the same reason: nothing but this machine writes to this
  file, so a file per device merges exactly while a shared one could only be
  merged by letting one device overwrite another.

  `sessions/1` folds the ticks into bounded periods of activity: ticks closer
  together than the gap belong to one session, a longer silence starts the
  next. Session *ends* cannot be observed — players are killed, laptops close,
  phones lock — so they are inferred from the silence rather than reported, and
  nothing has to remember to call a stop.

  ## Why the log folds as it is written

  A tick every five seconds is about seven hundred lines per film, and a year of
  watching is six megabytes of text. That matters here for a reason beyond
  disk: a directory syncs as one record per file, so the log is a single record
  whose content is the whole log — it would pass the sync document's five
  megabyte ceiling on its own, and re-upload entirely on every sync before it
  got there.

  So a tick that carries straight on from the line already at the end of the
  file — same key, beginning where that line ended — replaces it instead of
  appending: the timestamp moves to the latest tick and the seconds add up.
  Which is exactly what `sessions/1` would have computed from the unfolded
  lines, because a session's start is read back as `at - seconds` either way.

  Only where it carries straight on, and that condition is the whole of the
  correctness. A tick after a pause would also be inside the session, but
  merging it would move the start forward by the length of the pause and the
  session would claim to have begun later than it did. So a pause writes a
  second line, and a film watched straight through is one.
  """

  # Ticks this close together are one session.
  @gap 120

  # How much jitter still counts as "carried straight on". Folding is only safe
  # where the new tick begins where the last line ended, because a session's
  # start is read back as `at - seconds`: merging a tick that came after a
  # pause would move the start forward by the length of the pause, and the
  # session would claim to have begun later than it did. A paused film writes
  # two lines, which is the honest answer and still nothing next to the seven
  # hundred this is replacing.
  @slack 2

  @doc "Where this machine's tick log lives."
  def log_file do
    dir = Path.join(data_dir(), "ticks")
    File.mkdir_p(dir)
    Path.join(dir, "#{Laev.Position.device_id()}.log")
  end

  @doc """
  Record `seconds` of watching on `key` (`movie-603`, `tv-110316-s1e5`,
  `mal-1425-e12`).

  Called from `Laev.Position.record/2`, which every player goes through, so the
  mpv script, the VLC poller and a browser all land here. Nothing under a
  second is worth a line.
  """
  def tick(key, seconds, at \\ nil)

  def tick(key, seconds, at) when is_binary(key) and key != "" and is_integer(seconds) and seconds >= 1 do
    write(log_file(), {at || System.os_time(:second), key, seconds})
  end

  def tick(_key, _seconds, _at), do: :ok

  # Either extend the line at the end of the file or start a new one.
  defp write(path, {at, key, seconds}) do
    case open_tail(path) do
      {:ok, {last_at, ^key, last_seconds}, offset} when at - seconds <= last_at + @slack ->
        # The same watching, carrying straight on from where the last line
        # ended: the line moves to now and the seconds add up. Only ever the
        # final line of a file this device alone writes, so nothing another
        # machine holds is being rewritten.
        replace_tail(path, offset, {max(at, last_at), key, last_seconds + seconds})

      _ ->
        File.write(path, line({at, key, seconds}), [:append])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp line({at, key, seconds}), do: "#{at} #{key} #{seconds}\n"

  # The last line of the log and the byte offset it starts at. Only the tail is
  # read — the file is never loaded to append to it.
  defp open_tail(path) do
    with {:ok, %{size: size}} when size > 0 <- File.stat(path),
         read_from = max(size - 512, 0),
         {:ok, handle} <- :file.open(path, [:read, :binary]),
         {:ok, chunk} <- :file.pread(handle, read_from, size - read_from) do
      :file.close(handle)

      case String.split(chunk, "\n", trim: true) do
        [] ->
          :none

        parts ->
          last = List.last(parts)

          case parse(last) do
            [tick] -> {:ok, tick, size - byte_size(last) - 1}
            _ -> :none
          end
      end
    else
      _ -> :none
    end
  end

  defp replace_tail(path, offset, tick) do
    with {:ok, handle} <- :file.open(path, [:read, :write, :binary]),
         {:ok, _position} <- :file.position(handle, offset),
         :ok <- :file.truncate(handle),
         :ok <- :file.write(handle, line(tick)) do
      :file.close(handle)
      :ok
    else
      _ ->
        # Anything unexpected falls back to appending, which is always safe:
        # two lines of one session fold back together on the way out.
        File.write(path, line(tick), [:append])
    end
  end

  @doc """
  Every tick this account has, oldest first: `[{unix, key, seconds}]`.

  All devices' logs together, because a session is a fact about the account and
  the account is watched from more than one machine.
  """
  def ticks do
    dir = Path.join(data_dir(), "ticks")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&read_log(Path.join(dir, &1)))
        |> Enum.sort_by(fn {at, _key, _seconds} -> at end)

      _ ->
        []
    end
  end

  defp read_log(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&parse/1)
      _ -> []
    end
  end

  # A line laev did not write, or wrote half of when something was killed, is
  # skipped rather than allowed to end the parse: this log is only appended to
  # and never repaired.
  defp parse(line) do
    with [at, key, seconds] <- String.split(line, " ", parts: 3),
         {at, ""} <- Integer.parse(at),
         {seconds, ""} <- Integer.parse(String.trim(seconds)),
         true <- key != "" do
      [{at, key, seconds}]
    else
      _ -> []
    end
  end

  @doc """
  The ticks folded into sessions, oldest first:
  `[%{item:, started_at:, ended_at:, seconds:, keys:}]`.

  `item` is the title a session was of — a run of episodes in one evening is one
  session, as an evening is — and `keys` is every position key it touched, in
  order, so the episodes are still there to be listed.

  `gap` is the silence that separates two sessions, in seconds.
  """
  def sessions(gap \\ @gap) do
    ticks()
    |> Enum.group_by(fn {_at, key, _seconds} -> item(key) end)
    |> Enum.flat_map(fn {item, ticks} -> fold(item, ticks, gap) end)
    |> Enum.sort_by(& &1.started_at)
  end

  defp fold(item, ticks, gap) do
    ticks
    |> Enum.reduce([], fn {at, key, seconds}, acc ->
      case acc do
        [%{ended_at: ended} = open | rest] when at - ended <= gap ->
          [
            %{
              open
              | ended_at: max(at, ended),
                seconds: open.seconds + seconds,
                keys: if(key in open.keys, do: open.keys, else: open.keys ++ [key])
            }
            | rest
          ]

        _ ->
          # The first tick of a session is backdated by its own length, so a
          # session is never shorter than the watching it holds.
          [%{item: item, started_at: at - seconds, ended_at: at, seconds: seconds, keys: [key]} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  The title a position key belongs to: `tv-110316-s1e5` and `tv-110316-s2e1` are
  both `tv-110316`, because an evening of a show is one session however many
  episodes it ran to.
  """
  def item(key) when is_binary(key) do
    case Regex.run(~r/^(movie|tv|mal)-(\d+)/, key) do
      [matched, _type, _id] -> matched
      _ -> key
    end
  end

  def item(key), do: key

  @doc """
  The sessions of one day, in the machine's own timezone — which is what "what
  was I watching on Tuesday evening" means.
  """
  def sessions_on(%Date{} = date, gap \\ @gap) do
    Enum.filter(sessions(gap), fn session ->
      case DateTime.from_unix(session.started_at) do
        {:ok, moment} -> DateTime.to_date(moment) == date
        _ -> false
      end
    end)
  end

  defp data_dir, do: Laev.Scope.dir()
end
