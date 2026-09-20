defmodule Laev.PositionForgetTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-forget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    File.mkdir_p!(Path.join(dir, "played"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp write(dir, sub, name, body), do: File.write!(Path.join([dir, sub, name]), body)
  defp names(dir, sub), do: dir |> Path.join(sub) |> File.ls!() |> Enum.sort()

  test "forgetting a show takes every episode with it", %{dir: dir} do
    write(dir, "positions", "tv-1399", "seen")
    write(dir, "positions", "tv-1399-s1e1", "done")
    write(dir, "positions", "tv-1399-e2", "900")
    write(dir, "played", "tv-1399-s1e1", "3000 120")

    assert Laev.Position.forget("tv", 1399) == 4
    assert names(dir, "positions") == []
    assert names(dir, "played") == []
  end

  test "a title whose id is a prefix of another is left alone", %{dir: dir} do
    write(dir, "positions", "movie-15", "done")
    write(dir, "positions", "movie-150", "done")
    write(dir, "positions", "movie-15-extra", "done")

    assert Laev.Position.forget("movie", 15) == 2
    assert names(dir, "positions") == ["movie-150"]
  end

  test "forgetting a title that isn't there is not an error", %{dir: dir} do
    write(dir, "positions", "movie-1", "done")

    assert Laev.Position.forget("movie", 99) == 0
    assert names(dir, "positions") == ["movie-1"]
  end

  test "what a removal would cost is counted before it happens", %{dir: dir} do
    for e <- 1..3, do: write(dir, "positions", "tv-500-e#{e}", "done")
    write(dir, "positions", "movie-1", "done")
    File.write!(Path.join(dir, "runtimes.json"), Jason.encode!(%{"tv-500" => 1440, "movie-1" => 6000}))

    assert %{seconds: 4320, entries: 3} = Laev.Stats.for_title("tv", 500)
    assert %{seconds: 6000, entries: 1} = Laev.Stats.for_title("movie", 1)
    assert %{seconds: 0, entries: 0} = Laev.Stats.for_title("tv", 999)
  end
end
