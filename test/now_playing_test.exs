defmodule Laev.NowPlayingTest do
  use ExUnit.Case, async: false

  alias Laev.NowPlaying

  @ctx %{type: "movie", tmdb_id: 438_631, title: "Dune", season: nil, episode: nil, anime: false}
  @stream %{url: "https://example.invalid/dune.mkv", filename: "Dune.2021.mkv"}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-np-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "played"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  # The tracker's own 5-second write is the liveness signal.
  defp heartbeat(dir, seconds_ago \\ 0) do
    path = Path.join([dir, "played", "movie-438631"])
    File.write!(path, "1200 0")
    File.touch!(path, System.os_time(:second) - seconds_ago)
  end

  test "a launch with a live player comes back with its context and stream", %{dir: dir} do
    NowPlaying.mark(@ctx, @stream)
    heartbeat(dir)

    assert {ctx, stream} = NowPlaying.current(true)
    assert ctx.type == "movie" and ctx.tmdb_id == 438_631
    assert ctx.title == "Dune"
    # Atom keys, like every other context in the play flow.
    assert stream.url == @stream.url and stream.filename == @stream.filename
  end

  test "a closed player is not playing anything", %{dir: dir} do
    NowPlaying.mark(@ctx, @stream)
    heartbeat(dir)

    refute NowPlaying.current(false)
  end

  test "a player that stopped writing is gone, whatever else is running", %{dir: dir} do
    NowPlaying.mark(@ctx, @stream)
    # Someone else's mpv can be up; only our tracker's heartbeat counts.
    heartbeat(dir, 60)

    refute NowPlaying.current(true)
  end

  test "a heartbeat inside the grace window still counts", %{dir: dir} do
    NowPlaying.mark(@ctx, @stream)
    heartbeat(dir, 10)

    assert NowPlaying.current(true)
  end

  test "nothing was ever launched" do
    refute NowPlaying.current(true)
  end

  test "a launch with no heartbeat at all is not live" do
    NowPlaying.mark(@ctx, @stream)

    refute NowPlaying.current(true)
  end

  test "an unreadable marker is ignored rather than raised", %{dir: dir} do
    File.write!(Path.join(dir, "now_playing.json"), "{not json")
    heartbeat(dir)

    refute NowPlaying.current(true)
  end

  test "a marker from before streams were recorded still opens the page", %{dir: dir} do
    NowPlaying.mark(@ctx, %{})
    heartbeat(dir)

    assert {ctx, stream} = NowPlaying.current(true)
    assert ctx.title == "Dune"
    # Nothing to replay from — the page copes, everything else works off ctx.
    assert stream.url == nil
  end

  test "clearing it forgets the launch", %{dir: dir} do
    NowPlaying.mark(@ctx, @stream)
    heartbeat(dir)
    NowPlaying.clear()

    refute NowPlaying.current(true)
  end
end
