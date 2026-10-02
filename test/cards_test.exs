defmodule Laev.CardsTest do
  use ExUnit.Case, async: false

  alias Laev.Cards

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-cards-#{System.unique_integer([:positive])}")
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

  # The full TMDB response is ten times the size and the rest of it is credits,
  # networks and image lists no row has ever read.
  test "only the fields a row is made of are kept" do
    Cards.put_many(%{
      {"tv", 1399} => %{
        "name" => "Game of Thrones",
        "first_air_date" => "2011-04-17",
        "poster_path" => "/x.jpg",
        "vote_average" => 8.4,
        "status" => "Ended",
        "seasons" => [%{"season_number" => 1, "episode_count" => 10, "air_date" => "2011-04-17", "overview" => "…"}],
        "created_by" => [%{"name" => "someone"}],
        "networks" => [%{"name" => "HBO"}]
      }
    })

    card = Cards.get("tv", 1399)

    assert card["name"] == "Game of Thrones"
    assert card["status"] == "Ended"
    assert card["seasons"] == [%{"season_number" => 1, "episode_count" => 10, "air_date" => "2011-04-17"}]
    refute Map.has_key?(card, "created_by")
    refute Map.has_key?(card, "networks")
    refute Map.has_key?(card, "laev_at"), "bookkeeping doesn't leak into the row"
  end

  test "asking for many returns only what is known" do
    Cards.put_many(%{{"tv", 1399} => %{"name" => "Game of Thrones"}})

    known = Cards.get_many([{"tv", 1399}, {"movie", 671}])

    assert Map.keys(known) == [{"tv", 1399}]
    assert Cards.get("movie", 671) == nil
  end

  # A show gains seasons; a film is finished being made.
  test "a show goes stale in a day, a film in a week" do
    now = System.os_time(:second)
    write_card({"tv", 1399}, now - 2 * 24 * 3600)
    write_card({"tv", 1400}, now - 3600)
    write_card({"movie", 671}, now - 2 * 24 * 3600)
    write_card({"movie", 672}, now - 8 * 24 * 3600)

    stale = Cards.stale([{"tv", 1399}, {"tv", 1400}, {"movie", 671}, {"movie", 672}])

    assert Enum.sort(stale) == [{"movie", 672}, {"tv", 1399}]
  end

  test "a card nobody has is not stale, it is missing" do
    assert Cards.stale([{"tv", 1399}]) == []
  end

  defp write_card(key, at) do
    Cards.put_many(%{key => %{"name" => "x"}})
    path = Path.join(Application.get_env(:laev_app, :data_dir), "cards.json")
    stored = path |> File.read!() |> Jason.decode!()
    disk = "#{elem(key, 0)}-#{elem(key, 1)}"
    File.write!(path, Jason.encode!(put_in(stored[disk]["laev_at"], at)))
  end
end
