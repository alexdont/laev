defmodule Laev.ToCompleteTest do
  use ExUnit.Case, async: true

  alias Laev.CLI

  defp behind(title, order \\ 0), do: %{title: title, caught_up: false, order: order}
  defp caught_up(title, order \\ 0), do: %{title: title, caught_up: true, order: order}
  defp held(title, order \\ 0), do: %{title: title, held: true, order: order}
  # Anime rows arrived without the key at all, and `not nil` is an ArgumentError.
  defp silent(title), do: %{title: title}

  test "the three sections come in order, each behind its own divider" do
    rows = [caught_up("C"), held("H"), behind("A")]

    assert CLI.divide_sections(rows) == [behind("A"), :caught_up, caught_up("C"), :on_hold, held("H")]
  end

  test "a section with nothing in it gets no divider" do
    assert CLI.divide_sections([behind("A")]) == [behind("A")]
    assert CLI.divide_sections([behind("A"), held("H")]) == [behind("A"), :on_hold, held("H")]
    assert CLI.divide_sections([]) == []
  end

  # A section can be the only one there is, divider included — it is still a
  # section, and saying so beats a bare list of things you put down.
  test "only-held rows still sit under their divider" do
    assert CLI.divide_sections([held("H")]) == [:on_hold, held("H")]
  end

  # The crash: an anime row carries no :caught_up, and being in progress it is
  # behind by definition.
  test "a row that says nothing about being caught up or held is behind" do
    assert CLI.divide_sections([silent("anime"), caught_up("C")]) == [silent("anime"), :caught_up, caught_up("C")]
    assert CLI.section_of(silent("anime")) == :behind
  end

  # Both of these took the page down once: a third sentinel row the list's
  # helpers had never been told about. They answer for anything now.
  test "a sentinel row is scenery, not a crash" do
    assert CLI.section_of(:more) == :behind
    assert CLI.section_of(:caught_up) == :behind
    assert CLI.divide_sections([behind("A"), :more]) == [behind("A"), :more]
  end

  test "rows with nothing said never raise" do
    assert CLI.divide_sections([silent("a"), silent("b")]) == [silent("a"), silent("b")]
  end

  # On hold wins: something you put down is not something you are up to date on,
  # even when both are true of it.
  test "held beats caught up" do
    assert CLI.section_of(%{held: true, caught_up: true}) == :on_hold
  end

  test "order within a section is kept" do
    rows = [behind("B", 2), behind("A", 1), caught_up("D", 4), caught_up("C", 3)]

    assert Enum.map(CLI.divide_sections(rows), &(is_map(&1) && &1.title)) ==
             ["A", "B", false, "C", "D"]
  end
end
