defmodule Laev.ConcludedTest do
  use ExUnit.Case, async: true

  alias Laev.Shelf

  alias Laev.CLI

  defp days_ago(n), do: Date.utc_today() |> Date.add(-n) |> Date.to_iso8601()

  # The signal is silence, not status: five years with nothing aired.
  test "a show silent for over five years is concluded" do
    assert Shelf.concluded?(%{"last_air_date" => days_ago(5 * 365 + 1)})
    assert Shelf.concluded?(%{"last_air_date" => "2010-05-23"})
  end

  test "a show that aired within five years is not" do
    refute Shelf.concluded?(%{"last_air_date" => days_ago(5 * 365 - 1)})
    refute Shelf.concluded?(%{"last_air_date" => days_ago(30)})
  end

  # TMDB's status is deliberately not consulted — it files K-dramas as Ended in
  # week one. A recent show reads not-concluded whatever the status says.
  test "status has no say" do
    refute Shelf.concluded?(%{"status" => "Ended", "last_air_date" => days_ago(100)})
    assert Shelf.concluded?(%{"status" => "Returning Series", "last_air_date" => days_ago(2000)})
  end

  test "a show nothing is known about is not concluded" do
    refute Shelf.concluded?(%{})
    refute Shelf.concluded?(%{"last_air_date" => nil})
    refute Shelf.concluded?(%{"last_air_date" => ""})
    refute Shelf.concluded?(%{"last_air_date" => "not a date"})
  end
end
