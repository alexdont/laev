defmodule Laev.CompletedTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, Resume, Scope, Shelf}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-completed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))

    File.write!(
      Path.join(dir, "anime.json"),
      Jason.encode!(%{
        "1" => %{"title" => "Cowboy Bebop", "episodes" => 26, "updated" => 1_700_000_000}
      })
    )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  defp finish(type, id), do: Position.set_watched(%{type: type, tmdb_id: id, season: nil, episode: nil}, true)

  test "films, series and anime all appear", %{scope: scope} do
    Scope.run(scope, fn ->
      finish("movie", 603)
      finish("tv", 1396)
      Position.set_watched(%{mal_id: 1}, true)

      kinds = Shelf.completed() |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == [:anime, :film, :series]
    end)
  end

  # An episode mark says an episode was watched, not that the show is finished.
  test "a part-watched show is not completed", %{scope: scope} do
    Scope.run(scope, fn ->
      Position.set_watched(%{type: "tv", tmdb_id: 1396, season: 1, episode: 1}, true)

      assert Shelf.completed() == []
    end)
  end

  test "an in-progress film is not completed either", %{scope: scope, dir: dir} do
    Scope.run(scope, fn ->
      # A position file holding seconds rather than the watched marker.
      File.write!(Path.join([dir, "positions", "movie-603"]), "1847")

      assert Shelf.completed() == []
    end)
  end

  # The question this page answers is "what was I watching around then", so the
  # order is when, not what.
  describe "the order" do
    test "newest first, by when it was actually watched", %{scope: scope} do
      Scope.run(scope, fn ->
        for id <- [1597, 693, 41_154], do: finish("movie", id)

        Resume.put("movie", 1597, %{"type" => "movie", "tmdb_id" => 1597, "title" => "Meet the Parents", "updated_at" => 1_000})
        Resume.put("movie", 693, %{"type" => "movie", "tmdb_id" => 693, "title" => "Meet the Fockers", "updated_at" => 2_000})
        Resume.put("movie", 41_154, %{"type" => "movie", "tmdb_id" => 41_154, "title" => "Little Fockers", "updated_at" => 3_000})

        assert Enum.map(Shelf.completed(), & &1.title) ==
                 ["Little Fockers", "Meet the Fockers", "Meet the Parents"]
      end)
    end

    # A sync rewrites every mark file, so the mark's own timestamp says "today"
    # for everything — sorting on it alone buried what the history remembers.
    test "undated rows sit after dated ones rather than leading", %{scope: scope} do
      Scope.run(scope, fn ->
        finish("movie", 603)
        finish("movie", 1597)

        Resume.put("movie", 1597, %{"type" => "movie", "tmdb_id" => 1597, "title" => "Meet the Parents", "updated_at" => 1_000})

        [first, second] = Shelf.completed()
        assert first.dated?, "the one the history knows comes first"
        assert first.title == "Meet the Parents"
        refute second.dated?
      end)
    end

    test "an anime is dated by what MyAnimeList says, which survives reinstalls", %{scope: scope} do
      Scope.run(scope, fn ->
        Position.set_watched(%{mal_id: 1}, true)

        assert [%{title: "Cowboy Bebop", at: 1_700_000_000, dated?: true}] = Shelf.completed()
      end)
    end
  end

  describe "names" do
    # The name cache had two thousand names and not Meet the Parents, which is
    # in the history with its title sitting right there.
    test "the history's own title is used when the cache has none", %{scope: scope} do
      Scope.run(scope, fn ->
        finish("movie", 1597)
        Resume.put("movie", 1597, %{"type" => "movie", "tmdb_id" => 1597, "title" => "Meet the Parents", "updated_at" => 1})

        assert [%{title: "Meet the Parents"}] = Shelf.completed()
      end)
    end

    test "something with no name anywhere is still listed, not dropped", %{scope: scope} do
      Scope.run(scope, fn ->
        finish("movie", 999_999)

        assert [%{title: title}] = Shelf.completed()
        assert title =~ "999999"
      end)
    end
  end

  test "the count matches the list", %{scope: scope} do
    Scope.run(scope, fn ->
      for id <- [603, 1597, 693], do: finish("movie", id)
      Laev.SessionCache.forget(:completed_count)

      assert Shelf.completed_count() == length(Shelf.completed())
      assert Shelf.completed_count() == 3
    end)
  end

  test "nothing watched is an empty list, not an error", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Shelf.completed() == []
      Laev.SessionCache.forget(:completed_count)
      assert Shelf.completed_count() == 0
    end)
  end
end
