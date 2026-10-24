defmodule Laev.EpisodePickTest do
  use ExUnit.Case, async: true

  alias Laev.{Episodes, FilePick}

  # You and I Are Polar Opposites: two MyAnimeList cours of 12 and 13, one
  # 25-episode TMDB season. The second cour is released as a pack named
  # "(13-25)" whose files are numbered 13..25.
  defp pack_files do
    for n <- 13..25 do
      %{"path" => "[Group] Seihantai na Kimi to Boku - #{n}v2 (1080p).mkv", "bytes" => 1_400_000_000 + n}
    end
  end

  defp pack_name, do: "[Group] Seihantai na Kimi to Boku (13-25) [1080p]"

  describe "a pack numbered across the whole season" do
    test "asked for TMDB episode 15, it picks the file named 15" do
      ctx = %{episode: 3, tmdb_episode: 15, season: 1, anime: true}

      assert Episodes.numbered_as(pack_name(), ctx) == 15

      {:ok, file} = FilePick.choose(pack_files(), 15, nil)
      assert file["path"] =~ "- 15v2"
    end

    # The bug as reported: asked for local episode 2, it returned "- 13v2" and
    # called it playable, because the largest file wins when nothing matches.
    test "asked for an episode no file holds, it says so rather than guessing" do
      assert FilePick.choose(pack_files(), 2, nil) == {:error, :no_file_for_episode}
    end

    test "a caller that really wants something can still ask for the largest" do
      assert {:ok, file} = FilePick.choose(pack_files(), 2, nil, fallback: :largest)
      assert file["path"] =~ "- 25v2"
    end

    test "a film still gets the largest file, which is the whole point there" do
      files = [
        %{"path" => "Film/sample.mkv", "bytes" => 30_000_000},
        %{"path" => "Film/Film.2024.2160p.mkv", "bytes" => 40_000_000_000}
      ]

      assert {:ok, %{"path" => "Film/Film.2024.2160p.mkv"}} = FilePick.choose(files, nil, nil)
    end
  end

  describe "a version marker is not an episode number" do
    test "13v2 is episode 13, not episode 2" do
      file = "[Group] Seihantai na Kimi to Boku - 13v2 (1080p).mkv"

      assert FilePick.names_episode?(file, nil, 13)
      refute FilePick.names_episode?(file, nil, 2)
    end

    test "a bare fansub file of another episode is rejected, its own accepted" do
      file = "Show - 13v2 (1080p).mkv"

      assert Episodes.wrong_numbering?(file, %{episode: 2, tmdb_episode: 2, season: 1, anime: true})
      refute Episodes.wrong_numbering?(file, %{episode: 13, tmdb_episode: 13, season: 1, anime: true})
    end
  end

  describe "a single release that names a different episode" do
    test "S02E01 asked for S1E2 is rejected, asked for S2E1 accepted" do
      file = "Show.S02E01.1080p.WEB-DL.mkv"

      assert Episodes.wrong_numbering?(file, %{episode: 2, season: 1, anime: false})
      refute Episodes.wrong_numbering?(file, %{episode: 1, season: 2, anime: false})
    end

    test "confirm turns a wrong file into an error and leaves a right one alone" do
      source = %{name: "Show.S02E01.1080p.WEB-DL"}
      wrong = {:ok, %{filename: "Show.S02E01.1080p.WEB-DL.mkv"}}

      assert Episodes.confirm(wrong, source, %{episode: 2, season: 1, anime: false}) ==
               {:error, :another_episode}

      assert Episodes.confirm(wrong, source, %{episode: 1, season: 2, anime: false}) == wrong
    end

    test "a pack whose picked file holds no such episode is rejected" do
      result = {:ok, %{filename: "[Group] Show - 13v2 (1080p).mkv"}}
      source = %{name: pack_name()}
      ctx = %{episode: 2, tmdb_episode: 2, season: 1, anime: true}

      assert Episodes.confirm(result, source, ctx) == {:error, :another_episode}
    end
  end

  describe "grouping releases by the number they use" do
    test "each release is asked for its own numbering" do
      ctx = %{episode: 3, tmdb_episode: 15, season: 1, anime: true}

      sources = [
        {%{name: pack_name()}, 0},
        {%{name: "[Group] Seihantai na Kimi to Boku 2nd Season - 03 (1080p)"}, 1}
      ]

      groups = Episodes.group_by_numbering(sources, ctx) |> Map.new()

      assert Map.keys(groups) |> Enum.sort() == [3, 15]
      assert [{%{name: name}, 0}] = groups[15]
      assert name =~ "(13-25)"
    end

    test "a range starting at one is just a season pack, numbered as asked" do
      ctx = %{episode: 3, tmdb_episode: 3, season: 1, anime: true}
      assert Episodes.numbered_as("[Group] Show (1-12) [1080p]", ctx) == 3
    end
  end
end
