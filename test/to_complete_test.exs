defmodule Laev.ToCompleteTest do
  use ExUnit.Case, async: true

  alias Laev.CLI

  defp behind(title), do: %{title: title, caught_up: false}
  defp caught_up(title), do: %{title: title, caught_up: true}
  # Anime rows arrived without the key at all, and `not nil` is an ArgumentError.
  defp silent(title), do: %{title: title}

  test "the divider sits between what you are behind on and what is caught up" do
    rows = [behind("A"), behind("B"), caught_up("C")]

    assert CLI.divide_at_caught_up(rows) == [behind("A"), behind("B"), :caught_up, caught_up("C")]
  end

  test "no divider when every row is on the same side" do
    assert CLI.divide_at_caught_up([behind("A")]) == [behind("A")]
    assert CLI.divide_at_caught_up([caught_up("C")]) == [caught_up("C")]
    assert CLI.divide_at_caught_up([]) == []
  end

  # The crash: an anime row carries no :caught_up, and being in progress it is
  # behind by definition.
  test "a row that says nothing about being caught up is behind" do
    rows = [silent("anime"), caught_up("C")]

    assert CLI.divide_at_caught_up(rows) == [silent("anime"), :caught_up, caught_up("C")]
  end

  test "rows with nothing said never raise" do
    assert CLI.divide_at_caught_up([silent("a"), silent("b")]) == [silent("a"), silent("b")]
  end
end
