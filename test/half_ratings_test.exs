defmodule Laev.HalfRatingsTest do
  use ExUnit.Case, async: true

  alias Laev.Ratings

  # TMDB has always stored half steps. Laev only ever offered whole ones, so a
  # film that was better than a seven and not an eight had to be rounded one
  # way or the other. MyAnimeList stores integers, so it still gets whole ones:
  # asking for 8.5 and quietly sending 9 is worse than not asking.

  describe "the scores offered" do
    test "whole ones are the ten words, highest first" do
      assert Ratings.score_steps(:whole) == Ratings.score_words()
      assert Ratings.score_steps(:whole) |> Enum.map(&elem(&1, 0)) == Enum.to_list(10..1//-1)
    end

    test "half ones are nineteen, ten down to one" do
      scores = Ratings.score_steps(:half) |> Enum.map(&elem(&1, 0))

      assert length(scores) == 19
      assert List.first(scores) == 10
      assert List.last(scores) == 1
      assert scores == Enum.sort(scores, :desc), "a picker reads downwards"
      assert 8.5 in scores
      assert 1.5 in scores
    end

    # Nothing below 1: "absolute trash" is already the floor, and TMDB's 0.5
    # would need a second word for the same thing.
    test "and nothing below one is offered" do
      assert Ratings.score_steps(:half) |> Enum.all?(fn {score, _word} -> score >= 1 end)
    end

    test "a half step takes the word below it with a plus" do
      steps = Map.new(Ratings.score_steps(:half))

      assert steps[9] == "banger"
      assert steps[8.5] == "really good+", "better than really good, not yet a banger"
      assert steps[8] == "really good"
      assert steps[1.5] == "absolute trash+"
    end

    test "every offered score has a word" do
      for {score, word} <- Ratings.score_steps(:half) do
        assert is_binary(word) and word != "", "#{score} had no word"
      end
    end
  end

  describe "what TMDB will take" do
    # The API layer always accepted halves — `Tmdb.rate/2` rounds to the
    # nearest half and refuses anything outside 0.5..10 — so every score the
    # picker now offers is one TMDB stores as given.
    test "every half step survives TMDB's rounding unchanged" do
      for {score, _word} <- Ratings.score_steps(:half) do
        assert Laev.Tmdb.round_half(score) == score, "#{score} would not be stored as given"
      end
    end
  end

  describe "the word for a score" do
    test "rounds to the nearest whole, as it did" do
      assert Ratings.score_word(8) == "really good"
      assert Ratings.score_word(8.5) == "banger"
      assert Ratings.score_word(7.4) == "pretty decent"
    end

    test "and clamps rather than crashing" do
      assert Ratings.score_word(0) == "absolute trash"
      assert Ratings.score_word(11) == "masterpiece"
      assert Ratings.score_word(nil) == nil
    end
  end
end
