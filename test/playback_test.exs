defmodule Laev.PlaybackTest do
  use ExUnit.Case, async: false

  alias Laev.{Playback, Position, Scope}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-playback-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{player: "browser"})}
  end

  defp ctx, do: %{type: "movie", tmdb_id: 603, season: nil, episode: nil}

  test "the web plays in the page, the terminal in a player", %{scope: scope} do
    assert Scope.run(scope, fn -> Playback.target() end) == :browser
    assert Playback.target() == :mpv, "nothing bound is the terminal, which has no page"

    theirs = Scope.new(scope.dir, %{player: "vlc"})
    assert Scope.run(theirs, fn -> Playback.target() end) == :vlc
  end

  # Most releases are h265 in Matroska, which no browser opens — those have to
  # go through Real-Debrid's transcode. Something a browser can read already
  # should not be transcoded, which costs quality for nothing.
  test "a browser-readable file is handed over directly", %{scope: scope} do
    stream = %{url: "https://example.test/film.mp4", filename: "Film.2024.1080p.mp4", id: "ABC"}

    Scope.run(scope, fn ->
      assert {:ok, source} = Playback.browser_source(ctx(), stream)
      assert source.kind == :direct
      assert source.url == stream.url
      assert source.mime == "video/mp4"
    end)
  end

  test "a source tells the page where to resume", %{scope: scope} do
    stream = %{url: "https://example.test/film.mp4", filename: "Film.mp4", id: "ABC"}

    Scope.run(scope, fn ->
      Position.record(ctx(), %{position: 1847.0, duration: 6000.0, watched: 1847.0, skipped: 0.0, finished: false, floor: 30})

      assert {:ok, %{resume_at: 1847}} = Playback.browser_source(ctx(), stream)
    end)
  end

  # The browser posts a position every few seconds, and each post is its own
  # request that remembers nothing — so what was watched since last time has to
  # come off the disk.
  test "progress accumulates across separate posts", %{scope: scope} do
    Scope.run(scope, fn ->
      Playback.progress(ctx(), 10, duration: 6000, interval: 10)
      Playback.progress(ctx(), 20, duration: 6000, interval: 10)
      Playback.progress(ctx(), 30, duration: 6000, interval: 10)

      assert %{watched: 30, skipped: 0} = Position.played(ctx())
    end)
  end

  test "a jump is skipped, not watched", %{scope: scope} do
    Scope.run(scope, fn ->
      Playback.progress(ctx(), 10, duration: 6000, interval: 10)
      Playback.progress(ctx(), 900, duration: 6000, interval: 10)

      assert %{watched: watched, skipped: skipped} = Position.played(ctx())
      assert watched == 10, "only the ten seconds actually played"
      assert skipped >= 880
    end)
  end

  test "past the end is watched, and under half a minute is the beginning", %{scope: scope} do
    Scope.run(scope, fn ->
      Playback.progress(ctx(), 12, duration: 6000, interval: 10)
      assert Position.saved_position(ctx()) == 0, "twelve seconds in is not a place to return to"

      Playback.progress(ctx(), 5200, duration: 6000, interval: 10)
      assert Position.finished?(ctx()), "past 85% is watched"
    end)
  end

  # A list of players that will not work is worse than a short list.
  test "only players that exist are offered" do
    web = Playback.available(:browser)
    terminal = Playback.available(:terminal)

    assert "browser" in web
    refute "browser" in terminal, "a terminal has no page to play in"
    assert "mpv" in terminal, "mpv is installed on this machine"
    assert Enum.all?(terminal, &(&1 in ["mpv", "vlc"]))
  end
end
