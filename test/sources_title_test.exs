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

  describe "shows" do
    test "a leading article separates two shows the same way" do
      refute ok?("Runner", nil, "The.Runner.S01E01.1080p.WEB-DL", :tv)
      assert ok?("The Runner", nil, "The.Runner.S01E01.1080p.WEB-DL", :tv)
      assert ok?("Silo", nil, "Silo.S03E01.2160p.ATVP.WEB-DL.HDR.H265", :tv)
    end

    test "a year in the release name doesn't break the match" do
      # Both readings are offered: "doctor who" at the year, "doctor who 2005"
      # at the season tag — TMDB calls it the first.
      assert ok?("Doctor Who", nil, "Doctor.Who.2005.S01E01.1080p.BluRay", :tv)
      assert ok?("Doctor Who 2005", nil, "Doctor.Who.2005.S01E01.1080p.BluRay", :tv)
    end

    test "a country tag belongs to the release, not the title" do
      assert ok?("The Office", nil, "The.Office.US.S05E01.1080p.WEB-DL", :tv)
      assert ok?("Shameless", nil, "Shameless.UK.S01E01.720p", :tv)
    end

    test "season packs and season-only tags are read the same way" do
      assert ok?("Silo", nil, "Silo.S03.COMPLETE.2160p.WEB-DL", :tv)
      assert ok?("Silo", nil, "Silo Season 3 1080p WEB-DL", :tv)
      refute ok?("Silo", nil, "The.Silo.S03.COMPLETE.2160p.WEB-DL", :tv)
    end
  end

  describe "titles in other languages" do
    test "a release named in the original language is the same film" do
      titles = ["Amélie", "Le Fabuleux Destin d'Amélie Poulain"]

      assert ok?(titles, "2001", "Le.Fabuleux.Destin.d.Amelie.Poulain.2001.1080p.BluRay.x264")
      assert ok?(titles, "2001", "Amelie.2001.1080p.BluRay.x264")
      # …and a different French film still isn't it
      refute ok?(titles, "2001", "Le.Fabuleux.Destin.de.Quelqu.un.Dautre.2001.1080p")
    end

    test "an accented title matches its unaccented release name" do
      assert ok?("Amélie", "2001", "Amelie.2001.1080p.BluRay.x264")
      assert ok?("La Haine", "1995", "La.Haine.1995.1080p.BluRay.x264")
    end

    test "a non-Latin title judges nothing, rather than refusing everything" do
      assert ok?(["기생충"], "2019", "Parasite.2019.1080p.BluRay.x264")
      # with the romanised title known, it judges again
      assert ok?(["Parasite", "기생충"], "2019", "Parasite.2019.1080p.BluRay.x264")
      refute ok?(["Parasite", "기생충"], "2019", "The.Parasite.2019.1080p.BluRay.x264")
    end

    test "a show in its original language" do
      titles = ["Money Heist", "La Casa de Papel"]

      assert ok?(titles, nil, "La.Casa.de.Papel.S01E01.1080p.NF.WEB-DL", :tv)
      assert ok?(titles, nil, "Money.Heist.S01E01.1080p.NF.WEB-DL", :tv)
    end
  end

  describe "an alternative title that is the neighbour" do
    # Real TMDB data: 2026 has at least four films called "Runner", and the
    # Greek one (Ο Πακετάς) lists "The Runner" as its US title — which is the
    # name of a different 2026 film. Accepting it would undo the whole thing.
    test "the primary title plus an article is not accepted as an alias" do
      accept = Sources.acceptable_titles("Runner", ["Ο Πακετάς", "Πακετάς", "The Runner", "O Paketas"])

      refute "The Runner" in accept
      assert "O Paketas" in accept
      assert ok?(accept, "2026", "Runner.2026.1080p.WEB-DL")
      assert ok?(accept, "2026", "O.Paketas.2026.1080p.WEB-DL")
      refute ok?(accept, "2026", "The.Runner.2026.1080p.WEB.H264-CUPCAKES")
    end

    test "it works the other way round too" do
      accept = Sources.acceptable_titles("The Runner", ["Runner", "Người chạy"])

      refute "Runner" in accept
      assert "Người chạy" in accept
    end

    test "a genuinely different regional name is kept" do
      accept = Sources.acceptable_titles("Runner", ["Corredora", "Entrega Al Límite"])

      assert "Corredora" in accept
      assert ok?(accept, "2026", "Corredora.2026.1080p.WEB-DL")
      assert ok?(accept, "2026", "Entrega.Al.Limite.2026.1080p.WEB-DL")
    end
  end

  defp ok?(titles, year, name, kind \\ :movie),
    do: Sources.release_ok?(name, List.wrap(titles), year, kind)
end
