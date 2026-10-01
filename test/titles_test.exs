defmodule Laev.TitlesTest do
  use ExUnit.Case, async: false

  alias Laev.Titles

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-titles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    :ok
  end

  test "a name is remembered and read back" do
    Titles.put(%{{"movie", 550} => "Fight Club"})

    assert Titles.get("movie", 550) == "Fight Club"
    assert Titles.get("tv", 550) == nil, "type is part of the key — a film and a show can share an id"
  end

  test "names merge rather than replace the file" do
    Titles.put(%{{"movie", 550} => "Fight Club"})
    Titles.put(%{{"tv", 1399} => "Game of Thrones"})

    assert Titles.get("movie", 550) == "Fight Club"
    assert Titles.get("tv", 1399) == "Game of Thrones"
  end

  test "a better name replaces a worse one" do
    Titles.put(%{{"tv", 4607} => "Lost"})
    Titles.put(%{{"tv", 4607} => "Lost (2004)"})

    assert Titles.get("tv", 4607) == "Lost (2004)"
  end

  test "nothing useful is stored" do
    Titles.put(%{{"movie", 1} => nil, {"movie", 2} => "", {"movie", 3} => :not_a_name})

    assert Titles.all() == %{}
  end

  test "an unknown title is simply nil" do
    assert Titles.get("movie", 999_999) == nil
  end
end
