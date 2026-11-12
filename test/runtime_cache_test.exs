defmodule Laev.RuntimeCacheTest do
  use ExUnit.Case, async: false

  alias Laev.{Scope, Stats}

  # A runtime laev cannot look up and one TMDB says doesn't exist used to be
  # written down identically, as `"unknown"`, for good. So a single run without
  # a TMDB key — or on a train, or during a TMDB outage — taught the cache that
  # every film it touched was zero seconds long, and every later run agreed with
  # it: 6,940 hours of watching read as 2,500.
  #
  # A failure to ask is now never written down, and a real "no runtime" is
  # dated, so it is asked about again eventually.

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-runtimes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    previous = Application.get_env(:laev, :data_dir)
    Application.put_env(:laev, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: Application.put_env(:laev, :data_dir, previous),
        else: Application.delete_env(:laev, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp position(dir, name, body), do: File.write!(Path.join([dir, "positions", name]), body)
  defp cache_file(dir), do: Path.join(dir, "runtimes.json")
  defp write_cache(dir, map), do: File.write!(cache_file(dir), Jason.encode!(map))
  defp raw(dir), do: File.read(cache_file(dir)) |> case(do: ({:ok, b} -> b; _ -> nil))
  defp keyless(fun), do: Scope.with_overrides(%{tmdb_key: nil, tmdb_token: nil}, fun)

  describe "a lookup that could not be made" do
    # The Done-when of the task: with no key, `Tmdb` answers `:no_tmdb_key`
    # without touching the network, so this runs offline and still exercises
    # the real path.
    test "leaves the cache exactly as it was", %{dir: dir} do
      position(dir, "movie-603", "done")
      position(dir, "movie-1122573", "seen")
      write_cache(dir, %{"movie-603" => 8160})

      before = raw(dir)
      keyless(fn -> Stats.all_time() end)

      assert raw(dir) == before,
             "a run that could not ask anybody anything must not write down what it failed to learn"
    end

    test "and writes no cache at all where there was none", %{dir: dir} do
      position(dir, "movie-603", "done")

      keyless(fn -> Stats.all_time() end)

      refute File.exists?(cache_file(dir)),
             "an empty cache is honest; a cache full of zeros is not"
    end

    test "is counted, so a caller can say the totals are short", %{dir: dir} do
      position(dir, "movie-603", "done")

      stats = keyless(fn -> Stats.all_time() end)

      assert stats.unmeasurable == 1
      assert stats.tmdb == false
    end

    test "while what is cached is still used", %{dir: dir} do
      position(dir, "movie-603", "done")
      write_cache(dir, %{"movie-603" => 8160})

      stats = keyless(fn -> Stats.all_time() end)

      assert stats.seconds == 8160
      assert stats.unmeasurable == 0, "nothing had to be looked up"
    end
  end

  describe "which errors are answers" do
    test "TMDB having nothing under an id is an answer; everything else is not" do
      assert Stats.answer?({:error, {:tmdb, 404, "The resource you requested could not be found."}})

      refute Stats.answer?({:error, :no_tmdb_key})
      refute Stats.answer?({:error, {:tmdb, 401, "Invalid API key"}})
      refute Stats.answer?({:error, {:tmdb, 429, "Too many requests"}})
      refute Stats.answer?({:error, {:tmdb, 500, "Internal error"}})
      refute Stats.answer?({:error, %Req.TransportError{reason: :timeout}})
      refute Stats.answer?({:error, %Req.TransportError{reason: :nxdomain}})
    end
  end

  describe "what the cache keeps" do
    test "a dated unknown is kept until it runs out", %{dir: dir} do
      now = System.os_time(:second)

      write_cache(dir, %{
        "movie-1" => "unknown:#{now - 60}",
        "movie-2" => "unknown:#{now - 40 * 24 * 60 * 60}",
        "movie-3" => 5820
      })

      known = Stats.known_runtimes()

      assert known["movie-1"] == :unknown, "learned a minute ago, still believed"
      refute Map.has_key?(known, "movie-2"), "forty days old: ask again"
      assert known["movie-3"] == 5820
    end

    # The shape older laevs wrote, where a failure and an answer looked the
    # same. Dropping them is what heals a cache this bug has already spoiled.
    test "an undated unknown is not believed at all", %{dir: dir} do
      write_cache(dir, %{"movie-1" => "unknown", "movie-2" => 5820})

      known = Stats.known_runtimes()

      refute Map.has_key?(known, "movie-1")
      assert known["movie-2"] == 5820
    end

    # The date says when the unknown was learned. Re-dating it whenever the
    # file happens to be rewritten would keep it alive for as long as laev is
    # used, and the thirty days would never come round.
    test "a later save does not refresh an unknown's date", %{dir: dir} do
      learned_at = System.os_time(:second) - 29 * 24 * 60 * 60

      write_cache(dir, %{"movie-1" => "unknown:#{learned_at}"})
      # Something to learn, from the anime list rather than the network, so the
      # cache is genuinely rewritten.
      File.write!(Path.join(dir, "anime.json"), Jason.encode!(%{"52991" => %{"seconds" => 1420, "episodes" => 28}}))
      position(dir, "mal-52991-e1", "done")

      keyless(fn -> Stats.all_time() end)

      assert raw(dir) =~ "unknown:#{learned_at}", "the date it was learned on, not today's"
      assert Stats.known_runtimes()["mal-52991"] == 1420, "and the run did write what it learned"
    end

    test "and junk in the file is ignored rather than fatal", %{dir: dir} do
      write_cache(dir, %{"movie-1" => "nonsense", "movie-2" => nil, "movie-3" => 5820})

      assert Stats.known_runtimes() == %{"movie-3" => 5820}
    end
  end
end
