defmodule Laev.Days do
  @moduledoc """
  How much was watched on each day.

  The mpv script appends a line every few seconds while something plays —
  `2026-09-25 5` — which is the only record of *when* watching happened.
  Nothing else has it: a position file holds a second within an episode, and
  its mtime is no help because a sync pull rewrites every one of them at once.

  Append-only on purpose. The player writes it, so the record survives laev
  being closed, mpv being killed and the machine losing power, none of which
  the escript would be around to record. The cost is a line every five
  seconds, so the file is folded back into one line per day whenever it gets
  long — reading it gives the same answer either way.
  """

  # Roughly a day of continuous watching before it is worth rewriting.
  @compact_above 5_000

  # No line can hold more than a day: during playback a line is a few seconds
  # of delta, and after `maybe_compact/2` it is one whole day. So a line that
  # claims more is proof of damage rather than an unusual evening, and a day
  # total of 184,756 hours is what reading them anyway looked like.
  #
  # These lines exist because compaction folded *already fused* lines, with the
  # lenient parser that read `2026-09-30 194322026-09-30 6` as 194,322,026
  # seconds, and wrote the sum back as one line. That destroyed the originals:
  # there is nothing to recover from `2026-09-30 194322026`, so the day reads
  # from whatever undamaged lines are left instead of from a fiction.
  @a_day 86_400

  @doc """
  Seconds watched per day, as `%{~D[2026-09-25] => 7320}`. Unparsable lines
  are skipped rather than fatal — it is a log, not a database.
  """
  def totals do
    logs()
    |> Enum.reduce(%{}, fn path, totals ->
      case File.read(path) do
        {:ok, body} ->
          totals = body |> String.split("\n", trim: true) |> Enum.reduce(totals, &add_line/2)
          if path == own_log(), do: maybe_compact(body, path)
          totals

        _ ->
          totals
      end
    end)
  end

  # Every device's log, plus the single file laev used to keep before the
  # calendar had to survive being synced.
  defp logs do
    own = own_log()
    dir = Path.dirname(own)
    legacy = Path.join([dir, "..", "watched.log"]) |> Path.expand()

    files = dir |> Path.join("*.log") |> Path.wildcard()
    if File.exists?(legacy), do: files ++ [legacy], else: files
  end

  defp own_log, do: Laev.Position.log_file()

  @doc """
  The last `days` days as a list of `{date, seconds}`, oldest first, with the
  quiet days present and zero — a heatmap needs the gaps as much as the marks.
  """
  def recent(days) when days > 0 do
    totals = totals()
    today = today()

    for offset <- (days - 1)..0//-1 do
      date = Date.add(today, -offset)
      {date, Map.get(totals, date, 0)}
    end
  end

  @doc "Longest run of consecutive days with something watched, up to today."
  def streak(day_list) do
    day_list
    |> Enum.reduce({0, 0}, fn {_date, seconds}, {best, current} ->
      current = if seconds > 0, do: current + 1, else: 0
      {max(best, current), current}
    end)
    |> elem(0)
  end

  @doc """
  Today by the wall clock, not UTC.

  The player stamps its lines with the local date, so the grid has to agree:
  read in UTC, an evening after midnight local would land on a day the
  renderer never draws.
  """
  def today, do: NaiveDateTime.local_now() |> NaiveDateTime.to_date()

  # A line is `<date> <seconds>`, and a day's total is the sum of the many
  # small lines the player appends as it goes.
  #
  # Two of these can arrive as one. A pulled log used to be written without its
  # final newline (see `Laev.Sync.apply_dir/3`), so the next line fused onto the
  # last: `2026-10-31 12026-11-01 1`. This parsed — `Integer.parse/1` is happy
  # to stop at the first non-digit — and read as **12,026 seconds** on the 31st,
  # three and a half hours that never happened, while the 1 second on the 1st
  # was lost. On a real account 64 such lines added 4,470 hours.
  #
  # So the seconds must be *only* digits now, and a line that carries two
  # entries is split at the seam, which is exact: what follows the seconds is a
  # full `YYYY-MM-DD`. Anything else is skipped, as any unparsable line is —
  # this is a log, not a database.
  defp add_line(line, totals) do
    line |> String.trim() |> String.split(" ", trim: true) |> days_from(totals)
  end

  defp days_from([date, tail | rest], totals) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, seconds, rest} <- seconds_and_rest(tail, rest),
         true <- seconds <= @a_day do
      days_from(rest, Map.update(totals, date, seconds, &(&1 + seconds)))
    else
      _ -> totals
    end
  end

  defp days_from(_tokens, totals), do: totals

  defp seconds_and_rest(tail, [] = rest) do
    case Integer.parse(tail) do
      {seconds, ""} -> {:ok, seconds, rest}
      _ -> :no
    end
  end

  defp seconds_and_rest(tail, rest) do
    case Regex.run(~r/^(\d+)(\d{4}-\d{2}-\d{2})$/, tail) do
      [_, seconds, next_date] -> {:ok, String.to_integer(seconds), [next_date | rest]}
      _ -> :no
    end
  end

  # Fold a log back into one line per day once it has grown past the point where
  # reading it line by line is silly. Only ever this machine's own log, and only
  # from its own lines — folding in another device's days would duplicate them
  # the next time both files are read.
  defp maybe_compact(body, path) do
    lines = String.split(body, "\n", trim: true)

    if length(lines) > @compact_above do
      folded =
        lines
        |> Enum.reduce(%{}, &add_line/2)
        |> Enum.sort_by(fn {date, _} -> Date.to_erl(date) end)
        |> Enum.map_join("\n", fn {date, seconds} -> "#{Date.to_iso8601(date)} #{seconds}" end)

      # Folding replaces a log with a summary of itself, and when the summary
      # was computed from damaged lines there was no way back. One copy of what
      # was folded is kept, overwritten each time, so there is.
      File.copy(path, path <> ".bak")
      File.write(path, folded <> "\n")
    end

    :ok
  rescue
    _ -> :ok
  end
end
