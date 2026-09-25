defmodule Laev.SourcesTitleTest do
  use ExUnit.Case, async: true

  alias Laev.Sources

  # 2026 released both "Runner" and "The Runner". Asking a text indexer for
  # one returns the other — at the time of writing, every public source for
  # "Runner 2026" is in fact The Runner — so these are the case this exists
  # for, kept as real release names rather than invented ones.
  describe "two films, one name" do
    test "a leading article is a different film, not a near match" do
      refute ok?("Runner", "2026", "The.Runner.2026.2160p.AMZN.WEB-DL.DV.HDR10+.MULTi.DDP5.1.Atmos.H265.MP4-BTM")
      refute ok?("Runner", "2026", "The Runner 2026 1080p AMZN WEB-DL DDP 5 1 H264-SPWEB")
      refute ok?("The Runner", "2026", "Runner.2026.1080p.WEB-DL.x265")
    end

    test "each film keeps its own releases" do
      assert ok?("Runner", "2026", "Runner.2026.1080p.WEB-DL.DDP5.1.H264-GROUP")
      assert ok?("The Runner", "2026", "The.Runner.2026.1080p.WEB.H264-CUPCAKES")
    end

    test "the same name a decade apart is a different film" do
      refute ok?("Runner", "2026", "Runner.2015.720p.HDTV.x264")
    end
  end

  describe "names that must still pass" do
    test "a year in the title itself is not mistaken for the release year" do
      assert ok?("Blade Runner 2049", "2017", "Blade.Runner.2049.2017.1080p.BluRay.x264")
      assert ok?("Blade Runner", "1982", "Blade.Runner.1982.REMASTERED.1080p.BluRay")
      # …and the sequel is still not the original
      refute ok?("Blade Runner", "1982", "Blade.Runner.2049.2017.1080p.BluRay.x264")
    end

    test "punctuation in a title survives release naming" do
      assert ok?("Mission: Impossible", "1996", "Mission.Impossible.1996.1080p.BluRay.x264-AMIABLE")
      assert ok?("The Man from U.N.C.L.E.", "2015", "The.Man.from.U.N.C.L.E.2015.1080p.BluRay")
      assert ok?("Spider-Man: No Way Home", "2021", "Spider-Man.No.Way.Home.2021.2160p.WEB-DL")
      assert ok?("WALL·E", "2008", "WALL-E.2008.1080p.BluRay.x264")
      assert ok?("Harold & Kumar Go to White Castle", "2004", "Harold.and.Kumar.Go.to.White.Castle.2004.1080p")
    end

    test "a tracker's own stamp on the front is not part of the title" do
      assert ok?("Runner", "2026", "www.TamilBlasters.pics - Runner (2026) 1080p HQ HDRip")
      assert ok?("Runner", "2026", "[RARBG] Runner 2026 1080p WEBRip x264")
      # …but stamping it doesn't smuggle the wrong film through either
      refute ok?("Runner", "2026", "www.Torrenting.com - The Runner 2026 1080p")
    end

    test "a release year can drift by one against TMDB" do
      assert ok?("Runner", "2026", "Runner.2025.1080p.WEB-DL")
    end
  end

  describe "nothing to judge by" do
    test "a name with no year is let through rather than guessed at" do
      assert ok?("Runner", "2026", "Runner 1080p WEB-DL")
    end

    test "a title that can't be normalised judges nothing" do
      assert ok?("君の名は。", "2016", "Kimi.no.Na.wa.2016.1080p.BluRay")
    end

    test "a missing year on our side still matches on the title" do
      assert ok?("Runner", nil, "Runner.2026.1080p.WEB-DL")
      refute ok?("Runner", nil, "The.Runner.2026.1080p.WEB-DL")
    end
  end

  defp ok?(title, year, name), do: Sources.movie_release_ok?(name, title, year)
end
