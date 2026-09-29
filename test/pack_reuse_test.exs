defmodule Laev.PackReuseTest do
  use ExUnit.Case, async: true

  alias Laev.{FilePick, Sources}

  # Reusing the season pack you are already watching turns "next episode" from
  # a search plus eight probes into one resolve. The whole thing rests on two
  # questions: is this a pack, and is the file it gave back really the episode
  # asked for.

  describe "is it a pack" do
    test "names that mean a whole season" do
      assert Sources.pack?("Lupin.the.3rd.Part.II.S01.COMPLETE.1080p.BluRay")
      assert Sources.pack?("Cowboy Bebop Season 1 1080p BluRay x265")
      assert Sources.pack?("[Group] GTO 01-43 [BDRip]")
      assert Sources.pack?("Monster.2022.S02.COMPLETE.REPACK.1080p.NF.WEB-DL")
      assert Sources.pack?("Some Show Batch 1080p")
    end

    test "names that mean one episode" do
      refute Sources.pack?("Silo.S03E01.2160p.ATVP.WEB-DL")
      refute Sources.pack?("Monster The Ed Gein Story S01E07 1080p WEB h264")
    end
  end

  describe "is this really the episode" do
    test "an exact season and episode match" do
      assert FilePick.names_episode?("Lupin.S01E13.1080p.mkv", 1, 13)
      refute FilePick.names_episode?("Lupin.S02E13.1080p.mkv", 1, 13)
    end

    test "E13 is not E1, and 13 is not 1" do
      # The reason this check exists: the largest-file fallback would hand back
      # episode 1 and nobody would notice until the wrong thing started.
      refute FilePick.names_episode?("Lupin.S01E01.1080p.mkv", 1, 13)
      refute FilePick.names_episode?("GTO - 01 [BDRip].mkv", nil, 13)
    end

    test "absolute numbering, the way anime packs are named" do
      assert FilePick.names_episode?("GTO - 24 [BDRip][1080p].mkv", nil, 24)
      assert FilePick.names_episode?("[Group] Cowboy Bebop - 05 [BD].mkv", nil, 5)
    end

    test "a year in the name is not an episode number" do
      # Asking for episode 24, given a file whose 2024 is a year.
      refute FilePick.names_episode?("GTO 2024 1080p.mkv", nil, 24)
      refute FilePick.names_episode?("Show.1080p.mkv", nil, 80)
    end

    test "a pack named without SxxExx still matches on the number" do
      # Live-action packs usually carry SxxExx; plenty of older ones don't.
      assert FilePick.names_episode?("Lupin - 13.mkv", 1, 13)
    end

    test "nothing to go on is not a match" do
      refute FilePick.names_episode?(nil, 1, 2)
      refute FilePick.names_episode?("Show.S01.COMPLETE.mkv", 1, nil)
    end
  end
end
