defmodule Laev.ShowEndedTest do
  use ExUnit.Case, async: false

  alias Laev.{Cards, CLI}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-ended-#{System.unique_integer([:positive])}")
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

  # The rule that stops a returning show being declared finished the night you
  # catch up with it: only TMDB's own word ends a show.
  test "a returning show is not ended" do
    Cards.put_many(%{{"tv", 241_609} => %{"name" => "Your Friends & Neighbors", "status" => "Returning Series"}})

    refute CLI.show_ended?(%{type: "tv", tmdb_id: 241_609})
  end

  test "ended and cancelled are the two words that end a show" do
    Cards.put_many(%{{"tv", 1399} => %{"name" => "Game of Thrones", "status" => "Ended"}})
    Cards.put_many(%{{"tv", 2316} => %{"name" => "The Office", "status" => "Canceled"}})

    assert CLI.show_ended?(%{type: "tv", tmdb_id: 1399})
    assert CLI.show_ended?(%{type: "tv", tmdb_id: 2316})
  end

  # A MAL entry is one season by construction; its last episode really is its end.
  test "an anime entry ends with its own last episode" do
    assert CLI.show_ended?(%{type: "tv", tmdb_id: 241_609, mal_id: 62_601})
  end

  test "a film has no seasons to wait for" do
    refute CLI.show_ended?(%{type: "movie", tmdb_id: 78})
  end
end
