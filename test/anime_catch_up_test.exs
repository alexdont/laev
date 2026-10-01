defmodule Laev.AnimeCatchUpTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, Ratings}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-catchup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp marked(mal_id) do
    Path.wildcard(Path.join([Application.get_env(:laev_app, :data_dir), "positions", "mal-#{mal_id}-e*"]))
    |> Enum.map(&(&1 |> Path.basename() |> String.replace("mal-#{mal_id}-e", "") |> String.to_integer()))
    |> Enum.sort()
  end

  # Starting at episode 7 of something you had been watching elsewhere: the list
  # says 7 watched, so laev says seven too rather than one.
  test "the list's count becomes marks for every episode up to it" do
    assert Ratings.catch_up(55_973, 7, "watching") == 7
    assert marked(55_973) == [1, 2, 3, 4, 5, 6, 7]
    refute Position.finished?(%{mal_id: 55_973}), "seven of twelve is not finished"
  end

  test "a second pass writes nothing" do
    Ratings.catch_up(55_973, 7, "watching")

    assert Ratings.catch_up(55_973, 7, "watching") == 0
    assert marked(55_973) == [1, 2, 3, 4, 5, 6, 7]
  end

  test "it fills gaps and leaves the rest alone", %{dir: dir} do
    File.write!(Path.join([dir, "positions", "mal-55973-e3"]), "640")

    assert Ratings.catch_up(55_973, 5, "watching") == 4
    assert marked(55_973) == [1, 2, 3, 4, 5]
    assert Position.mark_state(%{mal_id: 55_973, episode: 3}) == {:partial, 640},
           "a place in an episode is not something an update overwrites"
  end

  # The point of the whole loop: the finale flips the list to completed, and the
  # anime leaves the Watchlist because laev agrees.
  test "finishing it marks the anime itself" do
    Ratings.catch_up(55_973, 12, "completed")

    assert Position.finished?(%{mal_id: 55_973})
    assert marked(55_973) == Enum.to_list(1..12)
  end

  test "nothing watched writes nothing" do
    assert Ratings.catch_up(55_973, 0, "plan_to_watch") == 0
    assert marked(55_973) == []
  end
end
