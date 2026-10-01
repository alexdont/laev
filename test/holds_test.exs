defmodule Laev.HoldsTest do
  use ExUnit.Case, async: false

  alias Laev.Holds

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-holds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    :ok
  end

  test "a title is held until it is picked back up" do
    refute Holds.held?("tv", 1399)

    assert Holds.toggle("tv", 1399) == :held
    assert Holds.held?("tv", 1399)

    assert Holds.toggle("tv", 1399) == :released
    refute Holds.held?("tv", 1399)
  end

  test "holds are listed as titles, films and shows alike" do
    Holds.hold("tv", 1399)
    Holds.hold("movie", 129)

    assert Enum.sort(Holds.all()) == [{"movie", 129}, {"tv", 1399}]
    assert MapSet.member?(Holds.set(), {"tv", 1399})
  end

  # The key is the same name positions use, so the sync machinery carries holds
  # with no special case — and ids can't bleed into each other.
  test "one id is not another id's prefix" do
    Holds.hold("movie", 15)

    refute Holds.held?("movie", 150)
    assert Holds.all() == [{"movie", 15}]
  end

  test "nothing held is an empty list, not a failure" do
    assert Holds.all() == []
    assert Holds.set() == MapSet.new()
  end
end
