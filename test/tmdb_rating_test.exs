defmodule Laev.TmdbRatingTest do
  use ExUnit.Case, async: true

  alias Laev.Tmdb

  # TMDB rates in half steps from 0.5 to 10. Anything else has to come back nil
  # rather than be rounded into a score — a mistyped "88" must not become a 10,
  # and an empty answer must not become a 0.5.
  describe "the scale" do
    test "whole numbers pass through" do
      assert Tmdb.round_half(8) == 8.0
      assert Tmdb.round_half(10) == 10.0
      assert Tmdb.round_half(1) == 1.0
    end

    test "halves are the point — an episode can be an 8.5" do
      assert Tmdb.round_half(8.5) == 8.5
      assert Tmdb.round_half(0.5) == 0.5
    end

    test "anything between snaps to the nearest half" do
      assert Tmdb.round_half(8.4) == 8.5
      assert Tmdb.round_half(8.2) == 8.0
      assert Tmdb.round_half(7.74) == 7.5
    end

    test "outside the scale is not a rating" do
      assert Tmdb.round_half(0) == nil
      assert Tmdb.round_half(0.2) == nil
      assert Tmdb.round_half(10.5) == nil
      assert Tmdb.round_half(88) == nil
      assert Tmdb.round_half(-3) == nil
    end

    test "not a number at all" do
      assert Tmdb.round_half(nil) == nil
      assert Tmdb.round_half("8") == nil
    end
  end

  describe "without a session" do
    # Cleared explicitly rather than assumed: the suite reads the real config,
    # and on a machine where someone has run `laev tmdb login` the ambient
    # answer is the opposite of what this is testing.
    setup do
      previous = Application.get_env(:laev_app, :tmdb_session)
      Application.delete_env(:laev_app, :tmdb_session)

      on_exit(fn ->
        if previous, do: Application.put_env(:laev_app, :tmdb_session, previous)
      end)

      :ok
    end

    test "rating refuses rather than pretending" do
      refute Tmdb.account?()
      assert Tmdb.rate_episode(241_609, 1, 1, 8) == {:error, :no_session}
      assert Tmdb.rate_movie(438_631, 8) == {:error, :no_session}
      assert Tmdb.clear_episode_rating(241_609, 1, 1) == {:error, :no_session}
    end

    test "and reading your rating back is simply nothing" do
      assert Tmdb.episode_rating(241_609, 1, 1) == nil
      assert Tmdb.movie_rating(438_631) == nil
    end
  end
end
