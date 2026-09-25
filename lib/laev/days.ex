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

  @doc """
  Seconds watched per day, as `%{~D[2026-09-25] => 7320}`. Unparsable lines
  are skipped rather than fatal — it is a log, not a database.
  """
  def totals do
    case File.read(path()) do
      {:ok, body} ->
        totals = body |> String.split("\n", trim: true) |> Enum.reduce(%{}, &add_line/2)
        maybe_compact(body, totals)
        totals

      _ ->
        %{}
    end
  end

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

  defp add_line(line, totals) do
    with [date, seconds] <- String.split(String.trim(line), " ", parts: 2),
         {:ok, date} <- Date.from_iso8601(date),
         {seconds, _} <- Integer.parse(seconds) do
      Map.update(totals, date, seconds, &(&1 + seconds))
    else
      _ -> totals
    end
  end

  # Fold the log back into one line per day once it has grown past the point
  # where reading it line by line is silly. The totals are unchanged.
  defp maybe_compact(body, totals) do
    lines = body |> String.split("\n", trim: true) |> length()

    if lines > @compact_above do
      folded =
        totals
        |> Enum.sort_by(fn {date, _} -> Date.to_erl(date) end)
        |> Enum.map_join("\n", fn {date, seconds} -> "#{Date.to_iso8601(date)} #{seconds}" end)

      File.write(path(), folded <> "\n")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp path, do: Laev.Position.log_file()
end
