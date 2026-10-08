defmodule Laev.FranchisesTest do
  use ExUnit.Case, async: true

  alias Laev.Franchises

  # The curated data is compiled in, so these assert against what actually
  # ships. They deliberately lean on a few fixed TMDB ids: those are the point
  # of the file, and a typo in one is exactly the kind of thing that would
  # otherwise only surface as a franchise quietly failing to appear.
  @logan {"movie", 263_115}
  @iron_man {"movie", 1726}
  @order_of_the_phoenix {"movie", 675}
  @alien_earth {"tv", 157_239}
  @fight_club {"movie", 550}

  # The curated animation list: a studio filmography rather than a franchise,
  # which is a different shape with different invariants.
  @toy_story {"movie", 862}
  @elio {"movie", 1_022_787}
  @spider_verse {"movie", 324_857}

  test "the animation list holds the films it exists to answer for" do
    animation = Franchises.by_name("Animation")

    assert length(animation.entries) > 180, "a studio filmography, not a handful"

    for {type, id} <- [@toy_story, @elio, @spider_verse] do
      assert Enum.any?(animation.entries, &(&1.type == type and &1.tmdb_id == id)),
             "#{type} #{id} should be in the animation list"
    end
  end

  test "every animation entry is a dated, released film" do
    today = Date.utc_today() |> Date.to_iso8601()

    for entry <- Franchises.by_name("Animation").entries do
      assert entry.type == "movie", "#{entry.title} — the list is features only"
      assert entry.date =~ ~r/^\d{4}-\d{2}-\d{2}$/, "#{entry.title} has no release date"

      assert entry.date <= today,
             "#{entry.title} (#{entry.date}) isn't out yet — an unwatchable row can only ever read unwatched"
    end
  end

  # Everything is the default view; the studio tiers are cuts of it, and every
  # film belongs to at least one of them.
  test "animation tiers partition the list" do
    animation = Franchises.by_name("Animation")
    studios = Enum.reject(animation.tiers, &(&1.key == "all"))

    assert Enum.map(animation.tiers, & &1.key) |> List.first() == "all"
    assert length(Franchises.entries(animation, "all")) == length(animation.entries)

    for tier <- studios do
      films = Franchises.entries(animation, tier.key)
      assert films != [], "#{tier.label} is an empty tier"
    end

    covered = studios |> Enum.flat_map(&Franchises.entries(animation, &1.key)) |> Enum.uniq()
    assert length(covered) == length(animation.entries), "every film sits in some studio tier"
  end

  # The point of sorting by size: a search for a Shrek film must not be answered
  # with two hundred cartoons.
  test "a film in both lists prefers the smaller one" do
    assert [smaller | rest] = Franchises.lookup_all("movie", 862)
    assert smaller.name == "Animation" or length(smaller.entries) <= length(List.first(rest).entries)
  end

  # Ghibli: watched state has to reach these rows through the anime bridge,
  # since laev marks anime by MyAnimeList entry and these rows are TMDB films.
  @spirited_away {"movie", 129}
  @nausicaa {"movie", 81}

  test "the Ghibli canon is in the animation list, Nausicaä included" do
    ghibli = Franchises.entries(Franchises.by_name("Animation"), "ghibli")
    ids = MapSet.new(ghibli, &{&1.type, &1.tmdb_id})

    assert length(ghibli) > 20, "the canon, not a selection"
    assert MapSet.member?(ids, @spirited_away)

    assert MapSet.member?(ids, @nausicaa),
           "the film that founded the studio — TMDB credits it to Topcraft, so it is added by hand"
  end

  # TMDB's English title for it is the 1985 recut Miyazaki disowned, and rows
  # take their titles from TMDB — so this one carries its own.
  test "a film TMDB misnames carries the right title" do
    nausicaa =
      Franchises.by_name("Animation").entries
      |> Enum.find(&(&1.tmdb_id == 81))

    assert nausicaa.rename == "Nausicaä of the Valley of the Wind"
    assert Enum.all?(Franchises.by_name("Animation").entries, &(&1.tmdb_id == 81 or is_nil(&1.rename)))
  end

  test "every franchise has a name and entries" do
    for f <- Franchises.all() do
      assert is_binary(f.name) and f.name != ""
      assert f.entries != []
    end
  end

  test "a title finds its franchise by id, whatever was typed to get there" do
    assert %{name: "Harry Potter"} = Franchises.lookup(elem(@order_of_the_phoenix, 0), elem(@order_of_the_phoenix, 1))
  end

  test "a TV entry is matched like any other" do
    assert %{name: "Alien"} = Franchises.lookup(elem(@alien_earth, 0), elem(@alien_earth, 1))
  end

  test "a title in no curated franchise finds nothing" do
    assert Franchises.lookup(elem(@fight_club, 0), elem(@fight_club, 1)) == nil
    assert Franchises.lookup_all(elem(@fight_club, 0), elem(@fight_club, 1)) == []
  end

  test "a title in two franchises resolves to the more specific one" do
    {type, id} = @logan
    names = Enum.map(Franchises.lookup_all(type, id), & &1.name)

    assert "X-Men" in names and "Marvel" in names
    assert Franchises.lookup(type, id).name == "X-Men",
           "Logan should open the X-Men films, not all of Marvel"
  end

  test "detect returns every franchise a result set touches, narrowest first" do
    {t1, i1} = @logan
    {t2, i2} = @iron_man
    titles = [%{type: t1, id: i1}, %{type: t2, id: i2}]

    names = Enum.map(Franchises.detect(titles), & &1.name)

    assert "X-Men" in names and "Marvel" in names
    assert names == Enum.sort_by(names, &length(Enum.find(Franchises.all(), fn f -> f.name == &1 end).entries))
  end

  test "detect is empty for results in no franchise" do
    assert Franchises.detect([%{type: "movie", id: elem(@fight_club, 1)}]) == []
  end

  test "entries come back in release order, with the undated last" do
    for f <- Franchises.all() do
      dates = Enum.map(f.entries, &if(&1.date in [nil, ""], do: "9999", else: &1.date))
      assert dates == Enum.sort(dates), "#{f.name} is not in release order"
    end
  end

  test "tiers filter, and every tier has something in it" do
    for f <- Franchises.all(), Franchises.tiered?(f), tier <- f.tiers do
      entries = Franchises.entries(f, tier.key)
      assert entries != [], "#{f.name}/#{tier.key} is empty"
      assert length(entries) <= length(f.entries)
    end
  end

  test "an untiered franchise gives everything" do
    alien = Enum.find(Franchises.all(), &(&1.name == "Alien"))

    refute Franchises.tiered?(alien)
    assert Franchises.entries(alien, "all") == alien.entries
  end

  test "Prepare for Doomsday contains Essentials, rather than competing with it" do
    marvel = Enum.find(Franchises.all(), &(&1.name == "Marvel"))
    essentials = MapSet.new(Franchises.entries(marvel, "essential"), &{&1.tmdb_id, &1.season})
    prepare = MapSet.new(Franchises.entries(marvel, "doomsday"), &{&1.tmdb_id, &1.season})

    assert MapSet.subset?(essentials, prepare)
    assert MapSet.size(prepare) > MapSet.size(essentials)
  end

  test "a show that ran for years is listed a season at a time" do
    marvel = Enum.find(Franchises.all(), &(&1.name == "Marvel"))
    shield = Enum.filter(marvel.entries, &(&1.title =~ "Agents of S.H.I.E.L.D."))

    assert length(shield) > 1, "multi-year shows should be split by season"
    assert Enum.all?(shield, &is_integer(&1.season))
    # the point of splitting: the seasons sit apart in the timeline
    assert length(Enum.uniq(Enum.map(shield, &String.slice(&1.date, 0, 4)))) > 1
  end

  describe "where TMDB and IMDb disagree about what is one show" do
    # The Netflix anthology is one IMDb series with four seasons and four
    # separate TMDB shows. The scene numbers releases IMDb's way, and TMDB
    # carries no IMDb id for any of them — so without this, Torrentio cannot be
    # asked at all and the text search finds a fraction of what exists.
    @anthology %{113_988 => 1, 225_634 => 2, 286_801 => 3, 299_939 => 4}

    test "each season of Monster points at the one IMDb series" do
      for {tmdb_id, season} <- @anthology do
        assert %{imdb_id: "tt13207736", season: ^season} = Franchises.imdb_override("tv", tmdb_id),
               "tv/#{tmdb_id} should map to season #{season}"
      end
    end

    test "the seasons are distinct and in release order" do
      monster = Enum.find(Franchises.all(), &(&1.name == "Monster"))
      seasons = Enum.map(monster.entries, & &1.imdb_season)

      assert seasons == [1, 2, 3, 4], "release order and IMDb numbering agree here"
    end

    test "an IMDb series id finds the list it means" do
      # The answer TMDB's own reverse lookup gets wrong: it resolves this id to
      # an entity that 404s when fetched.
      assert %{name: "Monster"} = Franchises.by_imdb("tt13207736")
    end

    test "an ordinary IMDb id belongs to no curated list" do
      refute Franchises.by_imdb("tt1375666")
      refute Franchises.by_imdb("nonsense")
    end

    test "a title TMDB files correctly has no override" do
      assert Franchises.imdb_override("tv", elem(@alien_earth, 1)) == nil
      assert Franchises.imdb_override("movie", elem(@logan, 1)) == nil
    end

    test "every override carries both halves, or it is no use" do
      for f <- Franchises.all(), entry <- f.entries, entry.imdb_id do
        assert is_binary(entry.imdb_id) and entry.imdb_id =~ ~r/^tt\d+$/
        assert is_integer(entry.imdb_season) and entry.imdb_season > 0
      end
    end
  end

  test "a single-year show stays one entry with no season" do
    alien = Enum.find(Franchises.all(), &(&1.name == "Alien"))
    earth = Enum.find(alien.entries, &(&1.title == "Alien: Earth"))

    assert earth.season == nil
  end
end
