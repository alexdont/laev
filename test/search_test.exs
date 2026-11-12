defmodule Laev.SearchTest do
  use ExUnit.Case, async: true
  doctest Laev.Search

  alias Laev.Search

  # These rules were private to laev's `watch` flow, so roki wrote its own copy
  # of all of them — the spelling pairs, the year hint, the exact-title-first
  # ranking. One copy now, and the terminal is just a caller of it.

  describe "what a query asks for" do
    test "a title" do
      assert Search.parse("dune") == %{title: "dune", year: nil, imdb_id: nil}
    end

    test "a title and a year" do
      assert Search.parse("heat 1995") == %{title: "heat", year: 1995, imdb_id: nil}
      assert Search.parse("  blade runner 2049  ") == %{title: "blade runner", year: 2049, imdb_id: nil}
    end

    # A film whose name *is* a year, with nothing before it, is a title.
    test "a year alone is a title, not a year" do
      assert Search.parse("1917") == %{title: "1917", year: nil, imdb_id: nil}
      assert Search.parse("2012") == %{title: "2012", year: nil, imdb_id: nil}
    end

    test "and a number that is not a year stays in the title" do
      assert Search.parse("ocean's 11") == %{title: "ocean's 11", year: nil, imdb_id: nil}
      assert Search.parse("district 9") == %{title: "district 9", year: nil, imdb_id: nil}
    end

    test "an IMDb id, which is not a search at all" do
      assert Search.parse("tt0113277") == %{title: nil, year: nil, imdb_id: "tt0113277"}
      assert Search.parse("  TT13207736 ") == %{title: nil, year: nil, imdb_id: "tt13207736"}
    end

    test "and nothing sensible is still a map" do
      assert Search.parse("") == %{title: "", year: nil, imdb_id: nil}
      assert Search.parse(nil) == %{title: nil, year: nil, imdb_id: nil}
    end
  end

  describe "spelling" do
    # TMDB will not cross-match them: "In the Grey" is invisible to "gray".
    test "both spellings are searched, the typed one first" do
      assert Search.variants("In the Gray") == ["In the Gray", "in the grey"]
      assert Search.variants("The Colour of Money") == ["The Colour of Money", "the color of money"]
    end

    test "a query with nothing to vary is searched once" do
      assert Search.variants("Dune") == ["Dune"]
    end

    test "and two spellings of a title compare equal" do
      assert Search.canonical("In the Grey") == Search.canonical("in the gray")
      assert Search.canonical("  Honor  ") == Search.canonical("honour")
      refute Search.canonical("Heat") == Search.canonical("Heat 2")
    end

    test "canonical survives a title that is not there" do
      assert Search.canonical(nil) == ""
    end
  end

  describe "the order results come back in" do
    defp title(name, year, popularity), do: %{title: name, year: year, popularity: popularity}

    test "an exact title beats a popular near-miss" do
      results = [title("Dune: Part Two", "2024", 900.0), title("Dune", "2021", 100.0)]

      assert [first | _] = Search.rank(results, "dune")
      assert first.title == "Dune"
    end

    # A remake is usually what somebody typing the name today means.
    test "and the newest exact title comes first" do
      results = [title("Heat", "1995", 50.0), title("Heat", "2026", 10.0)]

      assert Search.rank(results, "heat") |> Enum.map(& &1.year) == ["2026", "1995"]
    end

    test "the rest by popularity" do
      results = [title("Dune Drifter", "2020", 1.0), title("Dune: Part Two", "2024", 900.0)]

      assert Search.rank(results, "dune") |> Enum.map(& &1.title) == ["Dune: Part Two", "Dune Drifter"]
    end

    test "a year in the query outranks both" do
      results = [title("Heat", "2026", 900.0), title("The Heat Is On", "1995", 1.0)]

      assert [first | _] = Search.rank(results, "heat", 1995)
      assert first.title == "The Heat Is On", "the year beats even an exact title"
    end

    # Release dates shift between regions and announcements, so a year is a
    # hint and not a filter.
    test "and a year is soft to one either side" do
      results = [title("A", "2020", 1.0), title("B", "1996", 1.0), title("C", "1995", 1.0)]

      assert Search.rank(results, "nothing exact", 1995) |> Enum.map(& &1.title) == ["C", "B", "A"]
    end

    test "a spelling variant still counts as the exact title" do
      results = [title("In the Grey", "2026", 1.0), title("Grey Gardens", "1975", 500.0)]

      assert [first | _] = Search.rank(results, "in the gray")
      assert first.title == "In the Grey"
    end

    test "it takes the parsed query too" do
      results = [title("Heat", "2026", 900.0), title("Heat", "1995", 50.0)]
      parsed = Search.parse("heat 1995")

      assert [first | _] = Search.rank(results, parsed)
      assert first.year == "1995"
    end

    test "string keys and integer years work as well as atoms" do
      results = [%{"title" => "Dune", "year" => 2021, "popularity" => 1.0}]

      assert Search.rank(results, "dune") == results
    end

    test "and nothing to rank is not a crash" do
      assert Search.rank([], "dune") == []
    end
  end
end
