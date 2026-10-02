defmodule Laev.AnimeStatsTest do
  use ExUnit.Case, async: false

  alias Laev.{Anime, Position, Stats}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-anime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    # Two anime as MAL describes them: a 24-minute series and a 110-minute film.
    Anime.put_many(%{
      1425 => %{title: "Lupin III: Part II", episodes: 155, seconds: 1440, status: "completed", score: 9},
      164 => %{title: "Mononoke Hime", episodes: 1, seconds: 6600, status: "completed", score: 10}
    })

    {:ok, dir: dir}
  end

  defp mark(dir, name, body), do: File.write!(Path.join([dir, "positions", name]), body)

  test "an anime episode is keyed by its MAL entry, not by a TMDB show" do
    assert Position.set_watched(%{mal_id: 1425, episode: 12}, true) == :ok
    assert Position.mark_state(%{mal_id: 1425, episode: 12}) == :watched
    assert File.exists?(Path.join([Application.get_env(:laev_app, :data_dir), "positions", "mal-1425-e12"]))
  end

  test "episodes count at the length MAL gives that anime", %{dir: dir} do
    for n <- 1..10, do: mark(dir, "mal-1425-e#{n}", "seen")

    stats = Stats.all_time()

    assert stats.anime.seconds == 10 * 1440
    assert stats.anime.episodes == 10
    assert stats.anime.shows == 1
    assert stats.other.seconds == 0, "anime is not counted among films and shows"
  end

  # The whole-anime mark says "finished"; the episodes say how much. Counting both
  # in full would bill 155 episodes twice.
  test "a finished anime is not counted twice", %{dir: dir} do
    for n <- 1..155, do: mark(dir, "mal-1425-e#{n}", "seen")
    mark(dir, "mal-1425", "seen")

    assert Stats.all_time().anime.seconds == 155 * 1440
  end

  # Nothing else known about it: the mark claims the whole run, which is all
  # there is to go on.
  test "an anime marked finished with no episode marks counts for all of it", %{dir: dir} do
    mark(dir, "mal-1425", "seen")

    assert Stats.all_time().anime.seconds == 155 * 1440
  end

  test "a one-episode anime counts as a film at its own length", %{dir: dir} do
    mark(dir, "mal-164", "seen")

    stats = Stats.all_time()

    assert stats.anime.seconds == 6600
    assert stats.anime.films == 1
    assert stats.anime.episodes == 0
  end

  test "films and shows stay on their own side of the split", %{dir: dir} do
    mark(dir, "movie-872585", "seen")
    mark(dir, "mal-1425-e1", "seen")

    stats = Stats.all_time()

    assert stats.anime.episodes == 1
    assert stats.other.films == 1
    assert stats.seconds == stats.anime.seconds + stats.other.seconds
  end

  # What the home screen reads to know a finished anime has no next episode —
  # the row that used to add one to the last episode and hope.
  test "an anime's own episode count comes back offline" do
    assert Anime.episodes(1425) == 155
    assert Anime.episodes(164) == 1
    assert Anime.episodes(999_999) == nil
  end

  test "an anime's title comes back offline" do
    assert Anime.title(1425) == "Lupin III: Part II"
    assert Anime.title(999_999) == nil
  end

  # 155 episodes plus "I finished it" is 155 episodes, not 156.
  test "the whole-anime mark is not counted as another episode", %{dir: dir} do
    for n <- 1..155, do: mark(dir, "mal-1425-e#{n}", "seen")
    mark(dir, "mal-1425", "seen")

    row = Stats.all_time().titles |> Enum.find(&(&1.tmdb_id == 1425))

    assert row.finished == 155
    assert row.whole, "the anime is marked watched through"
  end

  test "an anime with only the whole mark counts no episodes", %{dir: dir} do
    mark(dir, "mal-1425", "seen")

    row = Stats.all_time().titles |> Enum.find(&(&1.tmdb_id == 1425))

    assert row.finished == 0
    assert row.whole
  end

  # The 85% rule, written down instead of recomputed: the picker always showed
  # these as watched; now the directory counters see the same thing.
  test "a position past 85% of the runtime becomes done", %{dir: dir} do
    mark(dir, "tv-241609-s2e6", "2429")

    assert Position.promote_finished(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}, 2700) == :promoted
    assert Position.mark_state(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}) == :watched
  end

  test "a position short of 85% stays a position", %{dir: dir} do
    mark(dir, "tv-241609-s2e6", "2429")

    assert Position.promote_finished(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}, 3300) == :ok
    assert Position.mark_state(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}) == {:partial, 2429}
  end

  test "promotion never rewrites words, only numbers", %{dir: dir} do
    mark(dir, "tv-241609-s2e6", "seen")

    assert Position.promote_finished(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}, 10) == :ok
    assert File.read!(Path.join([dir, "positions", "tv-241609-s2e6"])) == "seen"
  end

  test "the directory sweep promotes what the runtimes vouch for", %{dir: dir} do
    mark(dir, "tv-241609-s2e5", "3413")
    mark(dir, "tv-241609-s2e6", "600")
    mark(dir, "movie-78", "6500")
    mark(dir, "mal-1425-e3", "1300")
    mark(dir, "tv-241609", "seen")

    promoted =
      Position.promote_watched(fn name ->
        cond do
          String.starts_with?(name, "tv-241609-") -> 3300
          String.starts_with?(name, "movie-78") -> 7000
          String.starts_with?(name, "mal-1425-") -> 1440
          true -> nil
        end
      end)

    assert promoted == 3
    assert Position.mark_state(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 5}) == :watched
    assert Position.mark_state(%{type: "tv", tmdb_id: 241_609, season: 2, episode: 6}) == {:partial, 600}
    assert Position.mark_state(%{mal_id: 1425, episode: 3}) == :watched
  end

  # Anime moved from TMDB keys onto MAL keys; a position partway through an
  # episode should survive the move.
  test "a saved position is carried onto the new key", %{dir: dir} do
    mark(dir, "tv-1429-e5", "640")

    assert Position.adopt(%{type: "tv", tmdb_id: 1429, episode: 5}, %{
             type: "tv",
             tmdb_id: 1429,
             episode: 5,
             mal_id: 1425
           }) == :moved

    assert Position.mark_state(%{mal_id: 1425, episode: 5}) == {:partial, 640}
    refute File.exists?(Path.join([dir, "positions", "tv-1429-e5"]))
  end

  test "carrying over never overwrites a position already there", %{dir: dir} do
    mark(dir, "tv-1429-e5", "640")
    mark(dir, "mal-1425-e5", "900")

    Position.adopt(%{type: "tv", tmdb_id: 1429, episode: 5}, %{type: "tv", tmdb_id: 1429, episode: 5, mal_id: 1425})

    assert Position.mark_state(%{mal_id: 1425, episode: 5}) == {:partial, 900}
  end
end
