defmodule Laev.AutoPickTest do
  use ExUnit.Case, async: true

  # What plays when nobody is asked. Two rules, both the same idea: starting
  # the wrong file wastes more of an evening than being asked does.
  defp src(resolution, kind \\ "WEB"),
    do: {%{name: "release.#{resolution || "untagged"}", resolution: resolution, source: kind}, :stream}

  defp choose(list, cap), do: Laev.CLI.auto_choice(Enum.map(list, fn {r, k} -> src(r, k) end), cap)

  defp resolution_of({:play, {source, _stream}, _note}), do: source.resolution

  describe "the ceiling" do
    test "plays the best release that isn't above it" do
      have = [{"2160p", "BluRay"}, {"1080p", "BluRay"}, {"720p", "WEB"}]

      assert resolution_of(choose(have, "1080p")) == "1080p"
      assert resolution_of(choose(have, "720p")) == "720p"
      assert resolution_of(choose(have, "2160p")) == "2160p"
      assert resolution_of(choose(have, nil)) == "2160p"
    end

    test "says which ceiling it picked under" do
      assert {:play, _, " at 1080p or below"} = choose([{"1080p", "WEB"}], "1080p")
      assert {:play, _, " at 4K or below"} = choose([{"2160p", "WEB"}], "2160p")
      assert {:play, _, ""} = choose([{"2160p", "WEB"}], nil)
    end

    test "an untagged release is allowed rather than thrown away" do
      # Most of a real list carries no resolution in the name.
      assert resolution_of(choose([{nil, "WEB"}, {"720p", "WEB"}], "1080p")) == nil
    end
  end

  describe "what it refuses to start for you" do
    test "nothing under the ceiling means asking, not playing the 4K anyway" do
      assert {:ask, reason} = choose([{"2160p", "BluRay"}, {"2160p", "WEB"}], "1080p")
      assert reason =~ "nothing at 1080p or below"
    end

    test "a cam rip is never started, whatever its ceiling says" do
      # The week a film lands, "1080p" in a cam's name means nothing.
      assert {:ask, reason} = choose([{"1080p", "CAM"}, {"720p", "CAM"}], "1080p")
      assert reason =~ "cam rips"

      assert {:ask, _} = choose([{"1080p", "CAM"}], nil)
    end

    test "one decent release among the cams is still played" do
      assert resolution_of(choose([{"1080p", "CAM"}, {"720p", "WEB"}], "1080p")) == "720p"
    end

    test "the reason names the real problem, so the list makes sense when it opens" do
      assert {:ask, "nothing but cam rips so far"} = choose([{"2160p", "CAM"}], "2160p")
      assert {:ask, "nothing at 720p or below"} = choose([{"1080p", "WEB"}], "720p")
    end
  end

  describe "what the ceiling does not do" do
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
end
