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

  test "a single-year show stays one entry with no season" do
    alien = Enum.find(Franchises.all(), &(&1.name == "Alien"))
    earth = Enum.find(alien.entries, &(&1.title == "Alien: Earth"))

    assert earth.season == nil
  end
end
