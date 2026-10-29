defmodule Laev.StintsTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, Scope, Stints}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-stints-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  defp log_lines(dir) do
    Path.wildcard(Path.join([dir, "ticks", "*.log"]))
    |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true)))
  end

  describe "the log" do
    test "a tick writes a line, and nothing writes nothing", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        assert Stints.tick("movie-603", 5, 1_793_000_000) == :ok
        assert Stints.tick("movie-603", 0, 1_793_000_100) == :ok
        assert Stints.tick("movie-603", nil, 1_793_000_200) == :ok
        assert Stints.tick("", 5, 1_793_000_300) == :ok

        assert log_lines(dir) == ["1793000000 movie-603 5"]
      end)
    end

    test "two devices' logs are read together, in time order", %{scope: scope, dir: dir} do
      File.mkdir_p!(Path.join(dir, "ticks"))
      File.write!(Path.join([dir, "ticks", "aaa.log"]), "1793000200 movie-2 5\n")
      File.write!(Path.join([dir, "ticks", "bbb.log"]), "1793000100 movie-1 5\n")

      Scope.run(scope, fn ->
        assert Stints.ticks() == [{1_793_000_100, "movie-1", 5}, {1_793_000_200, "movie-2", 5}]
      end)
    end

    # The log is only appended to and never repaired, so a line something was
    # killed in the middle of must not end the parse.
    test "a half-written line is skipped and its neighbours survive", %{scope: scope, dir: dir} do
      File.mkdir_p!(Path.join(dir, "ticks"))

      File.write!(
        Path.join([dir, "ticks", "d.log"]),
        "1793000100 movie-1 5\n1793000150 movie-\nnonsense here\n1793000200 movie-2 7\n1793000250 movie-3 x\n"
      )

      Scope.run(scope, fn ->
        assert Stints.ticks() == [{1_793_000_100, "movie-1", 5}, {1_793_000_200, "movie-2", 7}]
      end)
    end
  end

  describe "sessions" do
    test "ticks inside the gap are one session, a silence starts another", %{scope: scope} do
      Scope.run(scope, fn ->
        for at <- [1_000, 1_005, 1_010], do: Stints.tick("movie-603", 5, at)
        for at <- [9_000, 9_005], do: Stints.tick("movie-603", 5, at)

        assert [first, second] = Stints.sessions()
        assert first.seconds == 15
        assert second.seconds == 10
        assert first.ended_at == 1_010
        assert second.started_at == 8_995
      end)
    end

    # A session is never shorter than the watching it holds.
    test "the first tick is backdated by its own length", %{scope: scope} do
      Scope.run(scope, fn ->
        Stints.tick("movie-603", 5, 1_000)

        assert [%{started_at: 995, ended_at: 1_000, seconds: 5}] = Stints.sessions()
      end)
    end

    test "an evening of one show is one session listing each episode", %{scope: scope} do
      Scope.run(scope, fn ->
        Stints.tick("tv-110316-s1e5", 60, 1_000)
        Stints.tick("tv-110316-s1e6", 60, 1_100)
        Stints.tick("tv-110316-s2e1", 60, 1_200)

        assert [session] = Stints.sessions()
        assert session.item == "tv-110316"
        assert session.keys == ["tv-110316-s1e5", "tv-110316-s1e6", "tv-110316-s2e1"]
        assert session.seconds == 180
      end)
    end

    # A paused film ends its session later than it watched, so the seconds are
    # the ticks' and not the wall time.
    test "seconds are the sum of ticks, not the span of the session", %{scope: scope} do
      Scope.run(scope, fn ->
        Stints.tick("movie-603", 5, 1_000)
        Stints.tick("movie-603", 5, 1_100)

        assert [%{seconds: 10, started_at: 995, ended_at: 1_100}] = Stints.sessions()
      end)
    end

    test "two titles the same evening are two sessions", %{scope: scope} do
      Scope.run(scope, fn ->
        Stints.tick("movie-1", 10, 1_000)
        Stints.tick("movie-2", 10, 1_050)

        assert [%{item: "movie-1"}, %{item: "movie-2"}] = Stints.sessions()
      end)
    end

    test "a day's sessions can be asked for", %{scope: scope} do
      Scope.run(scope, fn ->
        at = DateTime.utc_now() |> DateTime.to_unix()
        Stints.tick("movie-603", 30, at)

        today = DateTime.utc_now() |> DateTime.to_date()
        assert [%{item: "movie-603"}] = Stints.sessions_on(today)
        assert Stints.sessions_on(Date.add(today, -5)) == []
      end)
    end
  end

  describe "folding, which the sync cap makes necessary" do
    # A tick every five seconds is seven hundred lines a film, and the log syncs
    # as one record holding the whole file — six megabytes a year, against a
    # five megabyte ceiling.
    test "a continuing session stays one line", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        for n <- 0..99, do: Stints.tick("movie-603", 5, 1_000 + n * 5)

        assert length(log_lines(dir)) == 1
        assert log_lines(dir) == ["1793000000 movie-603 5" |> String.replace("1793000000", "1495") |> String.replace(" 5", " 500")]
      end)
    end

    # And it has to be invisible: a session folded on the way in must come out
    # as the session the unfolded lines would have produced.
    test "folded and unfolded lines fold into the same session", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        for n <- 0..9, do: Stints.tick("movie-603", 5, 1_000 + n * 5)
        [folded] = Stints.sessions()

        File.rm_rf!(Path.join(dir, "ticks"))
        File.mkdir_p!(Path.join(dir, "ticks"))

        lines = for n <- 0..9, do: "#{1_000 + n * 5} movie-603 5"
        File.write!(Path.join([dir, "ticks", "raw.log"]), Enum.join(lines, "\n") <> "\n")

        [unfolded] = Stints.sessions()

        assert folded.started_at == unfolded.started_at
        assert folded.ended_at == unfolded.ended_at
        assert folded.seconds == unfolded.seconds
      end)
    end

    test "a different title starts a new line", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        Stints.tick("movie-1", 5, 1_000)
        Stints.tick("movie-2", 5, 1_005)
        Stints.tick("movie-1", 5, 1_010)

        assert length(log_lines(dir)) == 3
      end)
    end

    test "a silence starts a new line", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        Stints.tick("movie-1", 5, 1_000)
        Stints.tick("movie-1", 5, 9_000)

        assert length(log_lines(dir)) == 2
      end)
    end
  end

  describe "the hook every player goes through" do
    test "recording a sample writes a tick", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        ctx = %{type: "movie", tmdb_id: 603, season: nil, episode: nil}

        Position.record(ctx, %{
          position: 300.0,
          duration: 6000.0,
          watched: 300.0,
          skipped: 0.0,
          finished: false,
          floor: 30,
          log_seconds: 60
        })

        assert [line] = log_lines(dir)
        assert line =~ "movie-603 60"
      end)
    end

    test "a sample that earned nothing writes no tick", %{scope: scope, dir: dir} do
      Scope.run(scope, fn ->
        ctx = %{type: "movie", tmdb_id: 603, season: nil, episode: nil}

        Position.record(ctx, %{
          position: 300.0,
          duration: 6000.0,
          watched: 300.0,
          skipped: 0.0,
          finished: false,
          floor: 30
        })

        assert log_lines(dir) == []
      end)
    end
  end

  test "ticks travel between devices" do
    assert :ticks in Laev.Sync.collections()
  end
end
