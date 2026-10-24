defmodule Laev.AnimeEntryMarkTest do
  use ExUnit.Case, async: false

  alias Laev.{CLI, Position, Scope}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-entry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))

    File.write!(
      Path.join(dir, "anime.json"),
      Jason.encode!(%{"1" => %{"title" => "Cowboy Bebop", "episodes" => 26}})
    )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{})}
  end

  # Anime has no season picker — a TMDB season is not what MyAnimeList counts,
  # so the entry list is where a season is chosen. It took every key but the
  # one that marks a season off, so finishing a 26-episode series watched
  # elsewhere meant opening it and ticking twenty-six rows.
  defp entry, do: %{id: "1", mal_id: 1, title: "Cowboy Bebop", subtype: "TV", episode_count: 26, year: "1998", poster: nil}

  test "one press marks a whole entry", %{scope: scope} do
    Scope.run(scope, fn ->
      CLI.toggle_anime_entry_watched(entry())

      assert Map.get(Position.anime_marks(), 1) == 26
      assert Position.finished?(%{mal_id: 1})
    end)
  end

  # Pressing it again on something already finished clears it — and the count
  # has to be read from disk for that, because the page cache holds its answer
  # for a couple of seconds, which is long enough to mark everything twice.
  test "a second press clears it", %{scope: scope} do
    Scope.run(scope, fn ->
      CLI.toggle_anime_entry_watched(entry())
      CLI.toggle_anime_entry_watched(entry())

      assert Map.get(Position.anime_marks(), 1, 0) == 0
      refute Position.finished?(%{mal_id: 1})
    end)
  end

  test "a partly watched entry is finished rather than cleared", %{scope: scope} do
    Scope.run(scope, fn ->
      for n <- 1..5,
          do: Position.set_watched(%{type: "tv", tmdb_id: nil, season: nil, episode: n, mal_id: 1}, true)

      assert Map.get(Position.anime_marks(), 1) == 5

      CLI.toggle_anime_entry_watched(entry())
      assert Map.get(Position.anime_marks(), 1) == 26
    end)
  end

  test "an entry with no episode count says so rather than marking nothing", %{scope: scope} do
    Scope.run(scope, fn ->
      unknown = %{entry() | mal_id: 9_999_999, episode_count: nil, id: nil}

      assert CLI.toggle_anime_entry_watched(unknown) == :ok
      assert Map.get(Position.anime_marks(), 9_999_999, 0) == 0
    end)
  end

  describe "what reaches MyAnimeList" do
    # A series ticked through in the terminal sat on the site saying
    # "watching, 3 of 26": ticking episodes here never told MyAnimeList
    # anything at all.
    test "the last episode completes the entry rather than leaving it watching" do
      assert Laev.MAL.progress_fields(26, 26) == %{
               status: "completed",
               finish_date: Date.to_iso8601(Date.utc_today()),
               num_watched_episodes: 26
             }

      assert %{status: "watching", num_watched_episodes: 25} = Laev.MAL.progress_fields(25, 26)
    end

    test "marking a whole entry sends the count that completes it", %{scope: scope} do
      Scope.run(scope, fn ->
        CLI.toggle_anime_entry_watched(entry())

        # 26 of 26 locally is what the push then sends, and 26 of 26 completes.
        assert Map.get(Position.anime_marks(), 1) == 26
        assert Laev.MAL.progress_fields(26, 26).status == "completed"
      end)
    end

    test "pushing nothing is not an update", %{scope: scope} do
      Scope.run(scope, fn ->
        assert CLI.push_anime_progress(%{mal_id: 1}) == :ok
        assert CLI.push_anime_progress(%{type: "tv", tmdb_id: 1}) == :ok, "no entry, nothing sent"
      end)
    end
  end

  describe "opening the entry under the cursor" do
    # ctrl-o only worked on the row outside the entry list, which resolves to
    # one entry for the whole show — so from a list naming season one and
    # season two there was no way to open season two.
    test "each entry links to its own MyAnimeList page" do
      assert CLI.entry_page_url(%{mal_id: 42_310, title: "Cyberpunk: Edgerunners"}) ==
               "https://myanimelist.net/anime/42310"

      assert CLI.entry_page_url(%{mal_id: 61_990, title: "Cyberpunk: Edgerunners 2"}) ==
               "https://myanimelist.net/anime/61990"
    end

    test "an entry with no id falls back to a search rather than the wrong page" do
      assert CLI.entry_page_url(%{mal_id: nil, title: "Some Show"}) =~ "anime.php?q=Some+Show"
    end
  end

  # macOS terminals send Option as a composed character rather than as Meta
  # unless somebody has changed a setting, so alt-w never reaches fzf there and
  # the hint named a key that does nothing.
  describe "the mark-through-here key" do
    test "the hint names a key that works on this platform" do
      expected = if match?({:unix, :darwin}, :os.type()), do: "ctrl-g", else: "alt-w"
      assert CLI.through_key() == expected
    end

    test "both keys are offered, so neither platform loses one" do
      source = File.read!("lib/laev/cli.ex")
      assert source =~ ~s(["ctrl-w", "alt-w", "ctrl-g"])
      assert source =~ ~s(when key in ["alt-w", "ctrl-g"])
    end
  end
end
