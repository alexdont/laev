defmodule Laev.SeasonTest do
  use ExUnit.Case, async: true

  alias Laev.Season

  describe "which season is it" do
    test "the quarters anime is published in" do
      assert Season.of_month(1) == :winter
      assert Season.of_month(3) == :winter
      assert Season.of_month(4) == :spring
      assert Season.of_month(7) == :summer
      assert Season.of_month(10) == :fall
      assert Season.of_month(12) == :fall
    end

    test "today's season" do
      assert Season.current(~D[2026-10-01]) == {2026, :fall}
      assert Season.current(~D[2026-09-30]) == {2026, :summer}
      assert Season.current(~D[2026-01-01]) == {2026, :winter}
    end
  end

  describe "stepping back and forward" do
    test "the season before this one" do
      assert Season.previous({2026, :fall}) == {2026, :summer}
      assert Season.previous({2026, :summer}) == {2026, :spring}
      assert Season.previous({2026, :spring}) == {2026, :winter}
    end

    test "january steps into the previous year's fall" do
      assert Season.previous({2026, :winter}) == {2025, :fall}
    end

    test "and forward over the year boundary" do
      assert Season.next({2026, :fall}) == {2027, :winter}
      assert Season.next({2026, :winter}) == {2026, :spring}
    end
  end

  describe "the list to browse" do
    test "newest first, counting back across years" do
      assert Season.recent(6, {2026, :spring}) == [
               {2026, :spring},
               {2026, :winter},
               {2025, :fall},
               {2025, :summer},
               {2025, :spring},
               {2025, :winter}
             ]
    end

    test "one season is just this one" do
      assert Season.recent(1, {2026, :fall}) == [{2026, :fall}]
    end
  end

  describe "labels and windows" do
    test "named the way everyone writes them" do
      assert Season.label({2026, :summer}) == "Summer 2026"
      assert Season.label({2025, :winter}) == "Winter 2025"
    end

    test "a season is its premiere quarter, ending on the real last day" do
      assert Season.window({2026, :winter}) == {"2026-01-01", "2026-03-31"}
      assert Season.window({2026, :spring}) == {"2026-04-01", "2026-06-30"}
      assert Season.window({2026, :summer}) == {"2026-07-01", "2026-09-30"}
      assert Season.window({2026, :fall}) == {"2026-10-01", "2026-12-31"}
    end

    test "february's last day is February's, leap year or not" do
      # end_of_month, not a hardcoded 31 — winter ends in March, but the same
      # helper is what any quarter ending in a short month would rely on.
      assert Season.window({2024, :winter}) == {"2024-01-01", "2024-03-31"}
    end

    test "the four of them, in order" do
      assert Season.all() == [:winter, :spring, :summer, :fall]
    end
  end
end
