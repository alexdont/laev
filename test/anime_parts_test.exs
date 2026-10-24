defmodule Laev.AnimePartsTest do
  use ExUnit.Case, async: false

  alias Laev.{Scope}
  alias Laev.Anime.Parts

  # You and I Are Polar Opposites, the case from the bug report: two
  # MyAnimeList entries of 12 and 13 episodes, one 25-episode TMDB season.
  @tmdb 278_043
  @first 60_371
  @second 63_832

  # Written out rather than read from this machine: the real cross-id list is in
  # the user's data directory, which other tests redirect, so these passed alone
  # and failed in the suite. The two entries below are exactly what the real
  # list holds for this show.
  setup do
    dir = Path.join(System.tmp_dir!(), "laev-parts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "anime-map.json"),
      Jason.encode!(%{
        "v" => 2,
        "fetched_at" => System.os_time(:second),
        "ids" => %{
          "#{@first}" => ["tv", @tmdb, 1, 19_010, 49_372],
          "#{@second}" => ["tv", @tmdb, 1, 19_983, 50_634],
          # Lupin III: one entry on its season, to prove nothing changes where
          # nothing was wrong.
          "21" => ["tv", 37_854, 1, 855, 1_234]
        }
      })
    )

    File.write!(
      Path.join(dir, "anime.json"),
      Jason.encode!(%{
        "#{@first}" => %{"title" => "Seihantai na Kimi to Boku", "episodes" => 12},
        "#{@second}" => %{"title" => "Seihantai na Kimi to Boku 2nd Season", "episodes" => 13},
        "21" => %{"title" => "Lupin III", "episodes" => nil}
      })
    )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{})}
  end

  test "both entries of a merged season are found, oldest first", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Parts.parts(@tmdb, 1) == [{@first, 12}, {@second, 13}]
    end)
  end

  test "an episode of the season lands in the right entry, numbered from its start", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Parts.locate(@tmdb, 1, 1) == {@first, 1}
      assert Parts.locate(@tmdb, 1, 12) == {@first, 12}
      assert Parts.locate(@tmdb, 1, 13) == {@second, 1}
      assert Parts.locate(@tmdb, 1, 15) == {@second, 3}
      assert Parts.locate(@tmdb, 1, 25) == {@second, 13}
    end)
  end

  test "and back again", %{scope: scope} do
    Scope.run(scope, fn ->
      for episode <- [1, 12, 13, 15, 25] do
        {mal, local} = Parts.locate(@tmdb, 1, episode)
        assert Parts.to_tmdb(@tmdb, 1, mal, local) == episode
      end
    end)
  end

  test "a whole title is rated under its first entry", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Parts.first_entry(@tmdb) == @first
    end)
  end

  test "a season's watched count adds up across its entries", %{scope: scope} do
    Scope.run(scope, fn ->
      marks = %{@first => 12, @second => 3}
      assert Parts.watched_in_season(@tmdb, 1, marks) == 15
    end)
  end

  # A season with one entry must behave exactly as the plain lookup does, so
  # nothing changes where nothing was wrong.
  test "a season with one entry is just that entry", %{scope: scope} do
    Scope.run(scope, fn ->
      assert [{mal, _}] = Parts.parts(37_854, 1)
      assert Parts.locate(37_854, 1, 7) == {mal, 7}
    end)
  end

  test "a season with no entry at all says so rather than guessing", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Parts.locate(999_999_999, 1, 1) == nil
      assert Parts.parts(999_999_999, 1) == []
    end)
  end

  test "the MyAnimeList page follows the season being watched", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Laev.Anime.page_url("tv", @tmdb, "…", 1) == "https://myanimelist.net/anime/#{@first}"
      assert Laev.Anime.entry_for("tv", @tmdb, 1) == @first
    end)
  end

  test "with no id to go on it falls back to a search", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Laev.Anime.page_url("tv", 999_999_999, "Some Show") =~ "anime.php?q=Some+Show"
    end)
  end
end
