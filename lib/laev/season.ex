defmodule Laev.Season do
  @moduledoc """
  The four anime seasons, which are what people actually mean by "this season".

  Anime is published in quarters — winter, spring, summer, fall — and talked
  about that way: a show is "a Summer 2026 anime", and the thing you want to
  browse is the whole quarter. "The previous season" is no use as a label; a
  list is only navigable if it says Summer 2026.

  A season is its premiere window, which is also how the charts everyone reads
  are built: a show belongs to the quarter it started in.
  """

  @seasons [
    {:winter, "Winter", 1, 3},
    {:spring, "Spring", 4, 6},
    {:summer, "Summer", 7, 9},
    {:fall, "Fall", 10, 12}
  ]

  @doc "The season happening now, as `{year, season}`."
  def current(today \\ Date.utc_today()), do: {today.year, of_month(today.month)}

  @doc "Which season a month falls in."
  def of_month(month) when month in 1..12 do
    {season, _label, _from, _to} = Enum.find(@seasons, fn {_s, _l, from, to} -> month >= from and month <= to end)
    season
  end

  @doc """
  This season and the ones before it, newest first — `[{2026, :fall}, {2026,
  :summer}, …]`. Counting back across a year boundary lands in the previous
  year's fall, which is what a reader expects to see next.
  """
  def recent(count, from \\ current()) when count > 0 do
    # //1 matters: 1..0 counts *down* in Elixir, so asking for one season
    # without it hands back three.
    Enum.reduce(1..(count - 1)//1, [from], fn _step, [latest | _] = acc -> [previous(latest) | acc] end)
    |> Enum.reverse()
  end

  @doc "The season before this one."
  def previous({year, :winter}), do: {year - 1, :fall}
  def previous({year, season}), do: {year, earlier(season)}

  @doc "The season after this one."
  def next({year, :fall}), do: {year + 1, :winter}
  def next({year, season}), do: {year, later(season)}

  @doc ~s(Human label, as everyone writes it: "Summer 2026".)
  def label({year, season}) do
    {_season, name, _from, _to} = Enum.find(@seasons, &(elem(&1, 0) == season))
    "#{name} #{year}"
  end

  @doc """
  The premiere window as `{from, to}` ISO dates — a show belongs to the season
  it started in, which is how every seasonal chart is built.
  """
  def window({year, season}) do
    {_season, _name, from, to} = Enum.find(@seasons, &(elem(&1, 0) == season))

    {Date.to_iso8601(Date.new!(year, from, 1)), Date.to_iso8601(Date.end_of_month(Date.new!(year, to, 1)))}
  end

  @doc "Every season name, in order."
  def all, do: Enum.map(@seasons, &elem(&1, 0))

  defp earlier(season) do
    names = all()
    Enum.at(names, Enum.find_index(names, &(&1 == season)) - 1)
  end

  defp later(season) do
    names = all()
    Enum.at(names, Enum.find_index(names, &(&1 == season)) + 1)
  end
end
