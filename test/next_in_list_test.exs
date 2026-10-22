defmodule Laev.NextInListTest do
  use ExUnit.Case, async: false

  alias Laev.Shelf

  alias Laev.{CLI, Franchises}

  defp ctx(type, id), do: %{type: type, tmdb_id: id, season: nil}

  # The real lookup, not a re-implementation of it: the guard being tested
  # lives inside next_in_list, and a helper that walks the entries itself would
  # pass whether or not the guard exists.
  defp next_after(ctx) do
    case CLI.next_in_list(ctx, CLI.onward_list(ctx)) do
      %{list: name, entry: entry} -> {name, entry.title}
      _ -> nil
    end
  end

  # The regression the Animation list nearly shipped: it is the only curated
  # list Toy Story 2 belongs to, and the film after it in release order across
  # eight studios is Fantasia 2000. A filmography has no next.
  test "a broad list never drives next-up" do
    assert {"Toy Story", "Toy Story 3"} = next_after(ctx("movie", 863))
  end

  test "a film whose only list is broad has no next at all" do
    refute CLI.onward_list(ctx("movie", 129)), "Spirited Away follows nothing in particular"
  end

  # Marvel is hand-ordered for exactly this, and must keep winning over the
  # three-film TMDB collection Iron Man also sits in.
  test "a curated franchise still beats TMDB's own collection" do
    assert {"Marvel", _} = next_after(ctx("movie", 1726))
  end

  # The row the user asked for: a filmography is a fine thing to browse, even
  # though it is a nonsense thing to be handed one-at-a-time.
  test "a broad list is still somewhere to jump to" do
    assert %{name: "Animation"} = CLI.browse_list(ctx("movie", 129))
    assert %{name: "Marvel"} = CLI.browse_list(ctx("movie", 1726))
  end

  # TMDB collections carry the announced ones too. Finishing Little Fockers
  # offered Focker-in-Law a month before it existed, and the only thing behind
  # that row was a source search that could not succeed.
  test "an unreleased entry is never handed over as next" do
    list = CLI.onward_list(ctx("movie", 1597))
    entries = Franchises.entries(list, "all")
    last_out = Enum.filter(entries, &(&1.date <= Date.to_iso8601(Date.utc_today()))) |> List.last()

    refute next_after(ctx("movie", last_out.tmdb_id)),
           "the film after the last released one isn't out yet"

    assert Enum.any?(entries, &(&1.date > Date.to_iso8601(Date.utc_today()))),
           "the list still shows what's coming — that is what a list is for"
  end

  # Opening a list you are partway through should land where you are, not at a
  # film one you have already watched twice.
  test "the cursor opens on the first thing not watched" do
    dir = Path.join(System.tmp_dir!(), "laev-cursor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev_app, :data_dir, previous),
        else: Application.delete_env(:laev_app, :data_dir)
    end)

    titles = for id <- [1597, 693, 41_154, 301_528], do: %{type: "movie", id: id, title: "film #{id}"}
    assert Shelf.first_unwatched_title(titles) == 0

    for id <- [1597, 693] do
      Laev.Position.set_watched(%{type: "movie", tmdb_id: id, season: nil, episode: nil}, true)
    end

    assert Shelf.first_unwatched_title(titles) == 2, "two behind you means the third"

    for id <- [41_154, 301_528] do
      Laev.Position.set_watched(%{type: "movie", tmdb_id: id, season: nil, episode: nil}, true)
    end

    assert Shelf.first_unwatched_title(titles) == 0, "nothing pending — the top is as good as anywhere"
  end

  test "something in no list has nowhere to jump" do
    refute CLI.browse_list(ctx("tv", 1396))
    refute CLI.onward_list(ctx("tv", 1396))
  end
end
