defmodule Laev.AnimeDetectionTest do
  use ExUnit.Case, async: false

  alias Laev.AnimeMap

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-detect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    # Tomb Raider King: TMDB files it as `ko`, MyAnimeList has it as Dogulwang.
    File.write!(
      Path.join(dir, "anime-map.json"),
      Jason.encode!(%{
        "fetched_at" => System.os_time(:second),
        "v" => 2,
        "ids" => %{"63316" => ["tv", 297_826, 1, 19_838, 50_480]}
      })
    )

    AnimeMap.forget()

    on_exit(fn ->
      File.rm_rf(dir)
      AnimeMap.forget()

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    :ok
  end

  # The language test alone calls this live action, which cost it its
  # scrobbler, its MyAnimeList rating row, and left it tracked twice.
  test "animation MyAnimeList lists is anime, whatever language TMDB filed it under" do
    assert AnimeMap.anime?("tv", 297_826)
    assert AnimeMap.mal_ids("tv", 297_826) == [63_316]
  end

  # The ids that make the anime source path work for it: AnimeTosho is
  # organized by AniDB, Torrentio by Kitsu.
  test "the tracker ids come along" do
    assert AnimeMap.anidb(63_316) == 19_838
    assert AnimeMap.kitsu_id(63_316) == 50_480
  end

  test "nothing the list doesn't carry becomes anime" do
    refute AnimeMap.anime?("tv", 1396)
    refute AnimeMap.anime?("movie", 872_585)
  end
end
