defmodule Laev.AutoPickTest do
  use ExUnit.Case, async: true

  # What plays when nobody is asked. The ceiling exists because "best" and
  # "biggest" are not the same answer: an 86GB 4K remux is the wrong pick on a
  # connection that can't carry it, however highly it ranks.
  defp source(resolution), do: {%{name: "release.#{resolution || "untagged"}", resolution: resolution}, :stream}

  defp pick(resolutions, cap) do
    {{source, _stream}, note} = Laev.CLI.best_within(Enum.map(resolutions, &source/1), cap)
    {source.resolution, note}
  end

  test "picks the best release that isn't above the ceiling" do
    have = ["2160p", "2160p", "1080p", "720p"]

    assert {"1080p", note} = pick(have, "1080p")
    assert note =~ "1080p or below"
    assert {"720p", _} = pick(have, "720p")
    assert {"2160p", _} = pick(have, "2160p")
  end

  test "no ceiling takes the top of the ranked list" do
    assert {"2160p", ""} = pick(["2160p", "1080p"], nil)
  end

  test "the list order decides between releases of the same size" do
    # Ranking already put the best first; the ceiling only filters.
    assert {"1080p", _} = pick(["1080p", "1080p", "720p"], "1080p")
  end

  test "an untagged release is allowed rather than thrown away" do
    # Most of a real list has no resolution in the name.
    assert {nil, _} = pick([nil, "720p"], "1080p")
  end

  test "when nothing fits, the smallest thing over the line plays, and says so" do
    assert {"1080p", note} = pick(["2160p", "2160p", "1080p"], "720p")
    assert note =~ "nothing at 720p or below"
  end

  test "4K-only means 4K, ceiling or not — playing nothing is worse" do
    assert {"2160p", note} = pick(["2160p", "2160p"], "720p")
    assert note =~ "nothing at 720p or below"
  end

  describe "what the ceiling does not do" do
    # The point of the default: the pick is capped, the list is not. A 4K you
    # didn't want to start automatically is still one keypress away.
    test "it never filters the list itself" do
      have = Enum.map(["2160p", "1080p", "720p"], &%{name: "r", resolution: &1})

      assert length(Laev.Sources.at_most(have, nil)) == 3
      assert Enum.map(Laev.Sources.at_most(have, "1080p"), & &1.resolution) == ["1080p", "720p"]
    end

    test "strict filtering keeps untagged releases, which are most of a list" do
      have = Enum.map(["2160p", nil, "720p"], &%{name: "r", resolution: &1})

      assert Enum.map(Laev.Sources.at_most(have, "1080p"), & &1.resolution) == [nil, "720p"]
    end

    test "the ladder is shared, so ceiling and filter can't disagree" do
      assert Laev.Sources.resolutions() == ["2160p", "1080p", "720p", "480p"]
      assert Laev.Sources.resolution_at_most?("1080p", "2160p")
      refute Laev.Sources.resolution_at_most?("2160p", "1080p")
    end
  end

  test "the note names the ceiling the way the setting does" do
    assert {_, note} = pick(["2160p"], "2160p")
    assert note =~ "4K", "2160p reads as 4K everywhere the user sees it"
  end
end
