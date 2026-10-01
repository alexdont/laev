defmodule Laev.AnimeMapTest do
  use ExUnit.Case, async: false

  alias Laev.AnimeMap

  # The cross-id list as it really comes: ids written both bare and as
  # one-element lists, and the TMDB season carried alongside.
  setup do
    dir = Path.join(System.tmp_dir!(), "laev-map-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    File.write!(
      Path.join(dir, "anime-map.json"),
      Jason.encode!(%{
        "fetched_at" => System.os_time(:second),
        "ids" => %{
          "16498" => ["tv", 1429, 1],
          "25777" => ["tv", 1429, 2],
          "164" => ["movie", 128]
        }
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

    {:ok, dir: dir}
  end

  test "a show's season answers with the MAL entry that is that season" do
    assert AnimeMap.mal_id("tv", 1429, 1) == 16498
    assert AnimeMap.mal_id("tv", 1429, 2) == 25777
    assert AnimeMap.mal_id("movie", 128, nil) == 164
  end

  # Scrobbling asks before it knows a season; season 1 is the only answer that
  # is right more often than it is wrong.
  test "a season-less show is taken as season one" do
    assert AnimeMap.mal_id("tv", 1429, nil) == 16498
  end

  # A TMDB show can be several anime: a search row is a TMDB row, and this is how
  # it finds the marks that belong to it.
  test "a TMDB show lists every MAL entry it is made of" do
    assert AnimeMap.mal_ids("tv", 1429) == [16_498, 25_777]
    assert AnimeMap.mal_ids("movie", 128) == [164]
    assert AnimeMap.mal_ids("tv", 1396) == []
  end

  test "anime is told apart from everything else, offline" do
    assert AnimeMap.anime?("tv", 1429)
    assert AnimeMap.anime?("movie", 128)
    refute AnimeMap.anime?("tv", 1396)
    refute AnimeMap.anime?("movie", 872_585)
  end

  test "no map on disk calls nothing anime rather than guessing", %{dir: dir} do
    File.rm!(Path.join(dir, "anime-map.json"))
    AnimeMap.forget()

    refute AnimeMap.ready?()
    refute AnimeMap.anime?("tv", 1429)
    assert AnimeMap.mal_ids("tv", 1429) == []
    assert AnimeMap.mal_id("tv", 1429, 1) == nil
  end
end
