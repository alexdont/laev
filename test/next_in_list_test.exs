defmodule Laev.NextInListTest do
  use ExUnit.Case, async: false

  alias Laev.{CLI, Franchises}

  defp ctx(type, id), do: %{type: type, tmdb_id: id, season: nil}

  defp next_after(ctx) do
    with %{} = list <- CLI.onward_list(ctx),
         entries <- Franchises.entries(list, "all"),
         index when is_integer(index) <- Enum.find_index(entries, &(&1.tmdb_id == ctx.tmdb_id)),
         %{} = entry <- Enum.at(entries, index + 1) do
      {list.name, entry.title}
    else
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

  test "something in no list has nowhere to jump" do
    refute CLI.browse_list(ctx("tv", 1396))
    refute CLI.onward_list(ctx("tv", 1396))
  end
end
