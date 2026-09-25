defmodule Laev.QualityTest do
  use ExUnit.Case, async: false

  alias Laev.Quality

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-q-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  # Real tallies, taken from the indexers while writing this.
  @web %{count: 29, best: "2160p", hd: 29, cam: 0}
  @cinema %{count: 12, best: "1080p", hd: 1, cam: 11}
  @cam_only %{count: 8, best: nil, hd: 0, cam: 8}
  @nothing %{count: 0, best: nil, hd: 0, cam: 0}

  describe "what the row says" do
    test "a film that's properly out leads with its best resolution" do
      assert Quality.badge(@web) == "4K"
      assert Quality.badge(%{@web | best: "1080p"}) == "1080p"
    end

    test "a film still in cinemas is called what it is" do
      # The single 1080p among eleven cam rips must not read as HD.
      assert Quality.badge(@cinema) == "mostly cam"
      assert Quality.badge(@cam_only) == "cam only"
    end

    test "nothing out yet is worth saying too" do
      assert Quality.badge(@nothing) == "no sources"
      assert Quality.badge(nil) == nil
    end
  end

  describe "what the preview says" do
    test "the full tally, in the order you'd read it" do
      assert Quality.line(@web) == "29 sources · best 2160p · 29 HD"
      assert Quality.line(@cinema) == "12 sources · best 1080p · 1 HD · 11 cam"
    end

    test "cam-only spells out that waiting is the move" do
      assert Quality.line(@cam_only) == "8 sources · 8 cam — nothing but cam rips yet"
    end

    test "and nothing means nothing" do
      assert Quality.line(@nothing) == "nothing on the indexers yet"
      assert Quality.line(nil) == nil
    end
  end

  describe "the cache" do
    test "a fresh tally is read back", %{dir: dir} do
      write(dir, "movie-1386315", @web)

      assert %{count: 29, best: "2160p", hd: 29, cam: 0} = Quality.cached("movie", 1_386_315)
    end

    test "a stale tally is ignored, so a film can come out in HD", %{dir: dir} do
      path = write(dir, "movie-1386315", @cam_only)
      File.touch!(path, System.os_time(:second) - 7 * 3600)

      refute Quality.cached("movie", 1_386_315)
    end

    test "nothing cached is not an error" do
      refute Quality.cached("movie", 999_999)
    end

    test "an unreadable file is ignored", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "quality"))
      File.write!(Path.join([dir, "quality", "movie-1"]), "{not json")

      refute Quality.cached("movie", 1)
    end
  end

  defp write(dir, name, tally) do
    File.mkdir_p!(Path.join(dir, "quality"))
    path = Path.join([dir, "quality", name])
    File.write!(path, Jason.encode!(tally))
    path
  end
end
