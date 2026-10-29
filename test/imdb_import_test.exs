defmodule Laev.ImdbImportTest do
  use ExUnit.Case, async: false

  alias Laev.{Csv, Position, Ratings, Scope, SessionCache, Shelf}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-imdb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  @header "Const,Your Rating,Date Rated,Title,Original Title,URL,Title Type,IMDb Rating,Runtime (mins),Year,Genres,Num Votes,Release Date,Directors"

  describe "reading the export" do
    # An IMDb row has quoted fields containing commas, and a film called
    # The "Burbs would otherwise eat the rest of its row.
    test "commas inside quotes stay inside the field" do
      row = ~s(tt26915336,8,2026-10-20,"Mars Express","Mars Express",https://x,Movie,7.5,88,2023,"Animation, Sci-Fi",15860,"2024-05-03","Jérémie Périn")

      assert [parsed] = Csv.maps(@header <> "\n" <> row <> "\n")
      assert parsed["Genres"] == "Animation, Sci-Fi"
      assert parsed["Title"] == "Mars Express"
      assert parsed["Date Rated"] == "2026-10-20"
    end

    test "a doubled quote is a literal quote" do
      row = ~s(tt0098987,7,2020-01-02,"The ""Burbs","The ""Burbs",https://x,Movie,6.7,101,1989,"Comedy",98000,"1989-02-17","Joe Dante")

      assert [parsed] = Csv.maps(@header <> "\n" <> row <> "\n")
      assert parsed["Title"] == ~s(The "Burbs)
    end

    test "a byte-order mark does not become part of a column name" do
      assert [parsed] = Csv.maps(<<0xEF, 0xBB, 0xBF>> <> @header <> "\ntt1,8,2020-01-01,T,T,u,Movie,1,1,2020,G,1,d,x\n")
      assert parsed["Const"] == "tt1"
    end

    test "a file that is not an export is refused rather than half-read", %{scope: scope} do
      Scope.run(scope, fn ->
        assert Ratings.import_imdb_csv("hello,world\n1,2\n") == {:error, :not_an_imdb_export}
        assert Ratings.import_imdb_csv("/no/such/file.csv") == {:error, :not_an_imdb_export}
      end)
    end
  end

  describe "a claimed date" do
    # Deliberately its own record: a session was observed and a measurement was
    # measured, while this is somebody's word for it — so it is not written as
    # a forged measurement or a tick claiming time nobody counted.
    test "is stored, read back, and grouped by title", %{scope: scope} do
      Scope.run(scope, fn ->
        ctx = %{type: "movie", tmdb_id: 603, season: nil, episode: nil}

        assert Position.watched_on(ctx) == nil
        Position.set_watched_on(ctx, 1_434_240_000)

        assert Position.watched_on(ctx) == 1_434_240_000
        assert Position.claimed_dates()["movie-603"] == 1_434_240_000
      end)
    end

    test "a show's episodes answer for the show", %{scope: scope} do
      Scope.run(scope, fn ->
        Position.set_watched_on(%{type: "tv", tmdb_id: 1396, season: 1, episode: 1}, 1_000)
        Position.set_watched_on(%{type: "tv", tmdb_id: 1396, season: 1, episode: 2}, 2_000)

        assert Position.claimed_dates()["tv-1396"] == 2_000, "the latest of them"
      end)
    end

    test "nonsense in the file is ignored rather than raised", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        File.mkdir_p!(Path.join(dir, "dated"))
        File.write!(Path.join([dir, "dated", "movie-1"]), "not a timestamp")

        assert Position.claimed_dates() == %{}
      end)
    end
  end

  describe "what the screens do with it" do
    test "the Completed page shows the claimed day, not the mark's", %{scope: scope} do
      Scope.run(scope, fn ->
        ctx = %{type: "movie", tmdb_id: 603, season: nil, episode: nil}
        Position.set_watched(ctx, true)
        Position.set_watched_on(ctx, 1_434_240_000)
        SessionCache.forget(:claimed_dates)

        assert [row] = Shelf.completed()
        assert row.dated?
        assert row.at == 1_434_240_000
      end)
    end

    # A date laev measured itself is the better answer and must win.
    test "a real session beats a claimed date", %{scope: scope} do
      Scope.run(scope, fn ->
        ctx = %{type: "movie", tmdb_id: 603, season: nil, episode: nil}
        Position.set_watched(ctx, true)
        Position.set_watched_on(ctx, 1_000)
        Laev.Stints.tick("movie-603", 3600, 9_000)
        SessionCache.forget(:claimed_dates)
        SessionCache.forget(:watch_dates)

        assert [%{at: 9_000}] = Shelf.completed()
      end)
    end

    test "an undated mark is still undated", %{scope: scope} do
      Scope.run(scope, fn ->
        Position.set_watched(%{type: "movie", tmdb_id: 603, season: nil, episode: nil}, true)
        SessionCache.forget(:claimed_dates)

        assert [%{dated?: false}] = Shelf.completed()
      end)
    end
  end

  test "claimed dates travel between devices" do
    assert :dated in Laev.Sync.collections()
  end

  describe "counts" do
    test "they say what happened, including what was not found", %{scope: scope} do
      Scope.run(scope, fn ->
        csv =
          @header <>
            "\ntt0000000000,8,2015-06-14,Nope,Nope,u,Movie,1,1,2015,G,1,d,x" <>
            "\ntt1,8,not-a-date,Bad,Bad,u,Movie,1,1,2015,G,1,d,x" <>
            "\ntt2,8,2013-03-01,Ep,Ep,u,TV Episode,1,1,2013,G,1,d,x\n"

        counts = Ratings.import_imdb_csv(csv)

        assert counts.skipped == 1, "the episode row"
        assert counts.unresolved >= 1, "the one that resolves to nothing"
        assert counts.dated == 0
      end)
    end
  end
end
