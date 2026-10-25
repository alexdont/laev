defmodule Laev.RokiParityTest do
  use ExUnit.Case, async: false

  alias Laev.{Config, Ratings, Scope, Sources, Tmdb}

  describe "one probe instead of four (Remux.Worker)" do
    # Four ffprobe runs each re-opened the same remote URL: about 5.7s before
    # the first segment against 1.4s for one call, measured on a real stream.
    setup do
      path = Path.join(System.tmp_dir!(), "laev-probe-#{System.unique_integer([:positive])}.mkv")

      {_out, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-loglevel error -f lavfi -i testsrc=size=160x120:rate=10 -f lavfi -i sine
             -f lavfi -i sine -t 2 -map 0:v -map 1:a -map 2:a
             -metadata:s:a:0 language=jpn -metadata:s:a:1 language=eng
             -c:v libx264 -preset ultrafast -c:a aac -y) ++ [path],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "it reads video, audio and languages in one call", %{path: path} do
      streams = Laev.Remux.Worker.probe_streams(path)

      assert Enum.any?(streams, &(&1.kind == "video" and &1.codec == "h264"))
      audio = Enum.filter(streams, &(&1.kind == "audio"))
      assert length(audio) == 2
      assert Enum.map(audio, & &1.lang) == ["jpn", "eng"]
    end

    test "a probe that fails leaves the old fallbacks" do
      assert Laev.Remux.Worker.probe_streams("/nonexistent/file.mkv") == []
    end
  end

  describe "settings overridden for one piece of work" do
    setup do
      dir = Path.join(System.tmp_dir!(), "laev-ovr-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, scope: Scope.new(dir, %{lang: "en", subs_lang: "en"})}
    end

    test "they sit on top of the scope and come off after", %{scope: scope} do
      Scope.run(scope, fn ->
        assert Config.lang() == "en"

        Scope.with_overrides(%{lang: "fr"}, fn ->
          assert Config.lang() == "fr"
          assert Config.subs_lang() == "en", "only what was overridden changes"
        end)

        assert Config.lang() == "en", "and nothing leaks out"
      end)
    end

    test "they nest, inner winning", %{scope: scope} do
      Scope.run(scope, fn ->
        Scope.with_overrides(%{lang: "fr"}, fn ->
          Scope.with_overrides(%{lang: "ja"}, fn -> assert Config.lang() == "ja" end)
          assert Config.lang() == "fr"
        end)
      end)
    end

    # The work that finds sources and starts a player happens elsewhere; an
    # override that did not follow it would apply to the page and not the film.
    test "they follow work handed to another process", %{scope: scope} do
      Scope.run(scope, fn ->
        Scope.with_overrides(%{lang: "fr"}, fn ->
          task = Scope.async(fn -> Config.lang() end)
          assert Task.await(task) == "fr"

          langs =
            Scope.async_stream([1, 2], fn _ -> Config.lang() end)
            |> Enum.map(fn {:ok, lang} -> lang end)

          assert langs == ["fr", "fr"]
        end)
      end)
    end

    test "an override restores even when the work raises", %{scope: scope} do
      Scope.run(scope, fn ->
        assert_raise RuntimeError, fn ->
          Scope.with_overrides(%{lang: "fr"}, fn -> raise "boom" end)
        end

        assert Config.lang() == "en"
      end)
    end
  end

  describe "keeping only releases whose audio has the language" do
    # Somebody learning French needs French speech; a French subtitle track on
    # a Japanese dub is not that.
    test "read tracks answer yes or no" do
      french = %{tracks: %{audio: [%{lang: "fre"}, %{lang: "eng"}]}}

      assert Sources.audio_in?(french, "fr") == true
      assert Sources.audio_in?(french, "ja") == false
    end

    # The third answer is the point: a release nobody has opened has no track
    # list, and calling that "no" would reject everything before anything could
    # be examined.
    test "a release whose tracks were never read says so" do
      assert Sources.audio_in?(%{}, "fr") == nil
      assert Sources.audio_in?(%{tracks: %{audio: []}}, "fr") == nil
    end

    test "strict_audio keeps the unexamined and drops the known-wrong" do
      sources = [
        release("a", tracks: %{audio: [%{lang: "fre"}]}),
        release("b", tracks: %{audio: [%{lang: "jpn"}]}),
        release("c", [])
      ]

      kept = Sources.rank(sources, strict_audio: "fr") |> Enum.map(& &1.name)

      assert "a" in kept
      assert "c" in kept, "not read yet is not a rejection"
      refute "b" in kept
    end
  end

  describe "a resolution limit before anything is probed" do
    test "the big ones are gone before they cost a check" do
      sources = [
        release("4k", resolution: "2160p"),
        release("hd", resolution: "1080p")
      ]

      assert Sources.rank(sources, max_resolution: "1080p") |> Enum.map(& &1.name) == ["hd"]
      assert length(Sources.rank(sources, [])) == 2
      assert length(Sources.rank(sources)) == 2, "rank/1 is unchanged"
    end
  end

  describe "languages a human typed" do
    test "every spelling of a language is the same language" do
      for value <- ["fr", "FR", " fre ", "fra", "French", "français"] do
        assert Config.normalise_lang(value) == "fr", value
      end

      assert Config.normalise_lang("jpn") == "ja"
      assert Config.normalise_lang("Japanese") == "ja"
    end

    test "off is off, and an unknown code is kept rather than lost" do
      for value <- ["off", "none", "", "  ", nil], do: assert(Config.normalise_lang(value) == nil)
      assert Config.normalise_lang("xx") == "xx"
    end
  end

  describe "the score words" do
    test "ten of them, highest first" do
      words = Ratings.score_words()

      assert length(words) == 10
      assert hd(words) == {10, "masterpiece"}
      assert List.last(words) == {1, "absolute trash"}
    end

    # A slider sends 7.5 and a stored rating sends 7; calling Float.round on
    # the integer is a crash, which is how this was found.
    test "it answers for integers and floats alike" do
      assert Ratings.score_word(8) == "really good"
      assert Ratings.score_word(8.0) == "really good"
      assert Ratings.score_word(7.5) == "really good"
      assert Ratings.score_word(7.4) == "pretty decent"
    end

    test "out of range still gets a word" do
      assert Ratings.score_word(0) == "absolute trash"
      assert Ratings.score_word(99) == "masterpiece"
      assert Ratings.score_word(-3) == "absolute trash"
    end
  end

  describe "what a browser cannot play without re-encoding" do
    test "heavy? is public and reads the codec" do
      assert Laev.Playback.heavy?(%{codec: "h265"})
      refute Laev.Playback.heavy?(%{codec: "h264"})
    end
  end

  describe "the cross-id list, checked rather than trusted" do
    # The Bleach suspicion turned out to be the list being right and the id it
    # was compared against being a different anime entirely.
    test "a show whose entries all point at it is consistent" do
      assert Laev.AnimeMap.consistent?("tv", 30_984) == :ok
    end

    test "a type it knows nothing about is not an accusation" do
      assert Laev.AnimeMap.consistent?("movie", 603) == :ok
      assert Laev.AnimeMap.consistent?("tv", 999_999_999) == :ok
    end
  end

  # The shape ranking reads, so a filter test is testing the filter rather than
  # tripping over a thin fixture.
  defp release(name, opts) do
    Enum.into(opts, %{
      name: "release.#{name}",
      resolution: "1080p",
      source: "WEB",
      seeders: 9,
      size: 2_000_000_000
    })
    |> Map.put(:name, name)
  end

  describe "recommendations" do
    @tag :network
    test "both calls answer in the trending card shape" do
      assert {:ok, [card | _]} = Tmdb.recommendations("movie", 603)

      for key <- [:id, :type, :title, :year, :poster, :overview, :vote, :popularity] do
        assert Map.has_key?(card, key), "card is missing #{key}"
      end

      assert card.poster =~ "image.tmdb.org"
      refute card.id == 603, "the title itself is not a recommendation"

      assert {:ok, similar} = Tmdb.similar("tv", 1396)
      assert length(similar) > 0
    end
  end
end
