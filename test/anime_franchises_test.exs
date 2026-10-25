defmodule Laev.AnimeFranchisesTest do
  use ExUnit.Case, async: true

  alias Laev.Franchises

  @anime ["Naruto", "Bleach", "Attack on Titan", "Demon Slayer", "Fate", "One Piece",
          "Dragon Ball", "Pokémon", "Detective Conan", "Yu-Gi-Oh!", "Mobile Suit Gundam",
          "Monogatari", "Cowboy Bebop", "Death Note", "Chainsaw Man", "Soul Eater"]

  test "the anime franchises are in the file" do
    names = Franchises.all() |> Enum.map(& &1.name)

    for name <- @anime, do: assert(name in names, "#{name} is missing")
  end

  # A lone show is not a franchise: there is nothing to put under an umbrella.
  test "every list has at least two parts" do
    for franchise <- Franchises.all() do
      assert length(franchise.entries) >= 2, "#{franchise.name} has #{length(franchise.entries)}"
    end
  end

  test "no entry is repeated within a list" do
    for franchise <- Franchises.all() do
      keys = Enum.map(franchise.entries, &{&1.type, &1.tmdb_id, &1[:season]})

      assert length(keys) == length(Enum.uniq(keys)), "#{franchise.name} repeats an entry"
    end
  end

  # Scoped to the generated lists. The older hand-written ones have one
  # deliberate exception — an Alien sequel with no announced date, where an
  # empty string is the honest answer — and changing that would be inventing a
  # date to satisfy a test.
  test "every generated date is a real ISO date" do
    for franchise <- generated(), entry <- franchise.entries do
      assert {:ok, _} = Date.from_iso8601(entry.date), "#{franchise.name}: #{inspect(entry.date)}"
    end
  end

  # A series is listed a season at a time, which is how release order survives a
  # franchise whose parts arrived over twenty years.
  # Also scoped: Marvel, Star Wars and Alien predate the season-at-a-time style
  # and list some shows whole, which works and is not worth rewriting.
  test "television entries name their season" do
    for franchise <- generated(), entry <- franchise.entries do
      if entry.type == "tv", do: assert(is_integer(entry[:season]), "#{franchise.name}: #{entry.title}")
    end
  end

  # The lists this test file is about: the generated anime ones.
  defp generated do
    hand_written = ["Marvel", "Alien", "Middle-earth", "Spider-Man", "Batman", "X-Men",
                    "The Hunger Games", "Star Wars", "Harry Potter", "Animation", "Monster", "Rocky"]

    Enum.reject(Franchises.all(), &(&1.name in hand_written))
  end

  describe "Bleach, the worked example" do
    # TMDB keeps Thousand-Year Blood War as season 2 of Bleach rather than as a
    # show of its own — tv 154494, which looked like it, is Lycoris Recoil.
    test "the series, both seasons, and the four films are one list" do
      bleach = Enum.find(Franchises.all(), &(&1.name == "Bleach"))

      seasons = for e <- bleach.entries, e.type == "tv", do: e.season
      films = for e <- bleach.entries, e.type == "movie", do: e.tmdb_id

      assert Enum.sort(seasons) == [1, 2]
      assert length(films) == 4
      assert 17_165 in films, "Fade to Black"
    end

    test "the series and a film both open the same list" do
      for {type, id} <- [{"tv", 30_984}, {"movie", 17_165}] do
        assert [%{name: "Bleach"}] = Franchises.all_for_title(%{type: type, id: id})
      end
    end

    # One list per title, not one per entry: a seven-season show used to answer
    # with its franchise seven times.
    test "a multi-season show names its list once" do
      assert Franchises.all_for_title(%{type: "tv", id: 4194}) |> Enum.map(& &1.name) == ["Star Wars"]
      assert Franchises.all_for_title(%{type: "tv", id: 30_984}) |> Enum.map(& &1.name) == ["Bleach"]
    end
  end

  describe "the long ones are tiered" do
    test "so they open as Series and Movies rather than one flat run" do
      for name <- ["One Piece", "Naruto", "Dragon Ball", "Detective Conan", "Pokémon"] do
        franchise = Enum.find(Franchises.all(), &(&1.name == name))

        assert Franchises.tiered?(franchise), "#{name} should be tiered"
        keys = Enum.map(franchise.tiers, & &1.key)
        assert "series" in keys and "movies" in keys, "#{name}: #{inspect(keys)}"
      end
    end

    test "every entry of a tiered list sits in a tier" do
      for name <- ["One Piece", "Naruto", "Pokémon"] do
        franchise = Enum.find(Franchises.all(), &(&1.name == name))

        for entry <- franchise.entries do
          assert entry.tiers != [], "#{name}: #{entry.title} is in no tier"
        end

        assert Franchises.entries(franchise, "series") != []
        assert Franchises.entries(franchise, "movies") != []
      end
    end
  end

  # Animation is a filmography rather than a franchise, so it must not drive
  # next-up; the anime lists are franchises and must.
  test "the anime lists are not broad" do
    for franchise <- Franchises.all(), franchise.name in @anime do
      refute Franchises.broad?(franchise), "#{franchise.name} should not be broad"
    end
  end

  test "a title in a small list and in Animation gets the small one first" do
    # Spirited Away is in Animation only; a Demon Slayer film is in both.
    demon = Enum.find(Franchises.all(), &(&1.name == "Demon Slayer"))
    film = Enum.find(demon.entries, &(&1.type == "movie"))

    assert [%{name: first} | _] = Franchises.all_for_title(%{type: "movie", id: film.tmdb_id})
    assert first == "Demon Slayer"
  end
end
