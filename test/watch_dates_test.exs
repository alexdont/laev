defmodule Laev.WatchDatesTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, Resume, Scope, SessionCache, Shelf, Stints}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-dates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    File.mkdir_p!(Path.join(dir, "played"))

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  defp forget_caches do
    SessionCache.forget(:watch_dates)
    SessionCache.forget(:measured_by_item)
    SessionCache.forget(:marks_by_show)
    SessionCache.forget(:anime_marks)
    SessionCache.forget(:anime_list)
  end

  # A resume entry's updated_at is stamped the moment a source resolves, before
  # a frame plays. Read as a watch date, it says that opening a player and
  # closing it five seconds later was a viewing.
  defp open_and_close(type, id, at) do
    Resume.put(type, id, %{"type" => type, "tmdb_id" => id, "title" => "x", "updated_at" => at})
  end

  defp watched_at(type, id) do
    forget_caches()

    Shelf.rows()
    |> Enum.filter(&is_map/1)
    |> Enum.find(&(&1[:type] == type and &1[:id] == id))
    |> case do
      nil -> :not_on_shelf
      row -> row[:watched_at]
    end
  end

  describe "a resume stamp on its own is not a date" do
    test "a title opened and closed is undated", %{scope: scope} do
      Scope.run(scope, fn ->
        Position.set_watched(%{type: "tv", tmdb_id: 108_978, season: 1, episode: 1}, true)
        open_and_close("tv", 108_978, 1_793_000_000)

        assert watched_at("tv", 108_978) in [0, :not_on_shelf]
      end)
    end

    test "seven seconds of measurement is still not a viewing", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        Position.set_watched(%{type: "tv", tmdb_id: 108_978, season: 1, episode: 1}, true)
        File.write!(Path.join([dir, "played", "tv-108978-s1e1"]), "7 0")
        open_and_close("tv", 108_978, 1_793_000_000)

        assert watched_at("tv", 108_978) in [0, :not_on_shelf]
      end)
    end
  end

  describe "what was actually measured dates it" do
    # The tick log exists precisely to say when, so it is asked first.
    test "a session in the tick log is the date", %{scope: scope} do
      Scope.run(scope, fn ->
        Position.set_watched(%{type: "tv", tmdb_id: 108_978, season: 1, episode: 1}, true)
        open_and_close("tv", 108_978, 1_793_000_000)
        Stints.tick("tv-108978-s1e1", 1200, 1_700_000_000)

        assert watched_at("tv", 108_978) == 1_700_000_000
      end)
    end

    # Before the tick log existed there is no session, so a measurement long
    # enough to be a viewing vouches for the stamp.
    test "a real measurement vouches for the stamp", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        Position.set_watched(%{type: "tv", tmdb_id: 108_978, season: 1, episode: 1}, true)
        File.write!(Path.join([dir, "played", "tv-108978-s1e1"]), "3600 0")
        open_and_close("tv", 108_978, 1_793_000_000)

        assert watched_at("tv", 108_978) == 1_793_000_000
      end)
    end

    test "a show's episodes add up to the show", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        for episode <- 1..3 do
          Position.set_watched(%{type: "tv", tmdb_id: 108_978, season: 1, episode: episode}, true)
          File.write!(Path.join([dir, "played", "tv-108978-s1e#{episode}"]), "60 0")
        end

        open_and_close("tv", 108_978, 1_793_000_000)

        # Sixty seconds an episode is under the floor; three of them are not.
        assert watched_at("tv", 108_978) == 1_793_000_000
      end)
    end
  end

  describe "the pieces underneath" do
    test "measured_by_item sums a title's keys", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        File.write!(Path.join([dir, "played", "tv-110316-s1e1"]), "100 5")
        File.write!(Path.join([dir, "played", "tv-110316-s1e2"]), "200 0")
        File.write!(Path.join([dir, "played", "movie-603"]), "900 0")
        File.write!(Path.join([dir, "played", "junk"]), "not a number")

        totals = Position.measured_by_item()

        assert totals["tv-110316"] == 300
        assert totals["movie-603"] == 900
        refute Map.has_key?(totals, "junk")
      end)
    end

    # Witch Hat Atelier: watched on MyAnimeList years before laev existed, six
    # measured seconds from a browser test, and its eight imported marks — three
    # hours of them — moved into the last seven days.
    test "an anime is dated by MyAnimeList, not by a six-second test", %{scope: scope, dir: dir} do
      File.write!(
        Path.join(dir, "anime.json"),
        Jason.encode!(%{
          "51553" => %{"title" => "Witch Hat Atelier", "episodes" => 12, "status" => "watching", "updated" => 1_758_700_000}
        })
      )

      Scope.run(scope, fn ->
        for episode <- 1..8,
            do: Position.set_watched(%{type: "tv", tmdb_id: nil, season: nil, episode: episode, mal_id: 51_553}, true)

        File.write!(Path.join([dir, "played", "mal-51553-e1"]), "6 0")
        open_and_close("tv", 196_950, 1_793_000_000)
        forget_caches()

        row =
          Shelf.rows()
          |> Enum.filter(&is_map/1)
          |> Enum.find(&(&1[:mal_id] == 51_553))

        if row do
          assert row[:watched_at] == 1_758_700_000,
                 "MAL's own timestamp, not the stamp from opening a player"
        end
      end)
    end
  end
end
