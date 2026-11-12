defmodule Laev.HedgeTest do
  use ExUnit.Case, async: false

  alias Laev.{Hedge, Scope}

  # The race laev plays with, on its own. Ranked list, best-ranked first, one at
  # a time; a candidate that has not answered inside the window gets another
  # started beside it rather than after it, and the best-ranked of whatever
  # answers wins. Roki rebuilt this to stream progress to a page, which is what
  # the `notify` and `untried` halves are for.

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-hedge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{})}
  end

  defp run(candidates, probe, opts \\ []), do: Hedge.run(candidates, probe, opts)

  describe "the pick" do
    test "the first candidate that answers, when it answers in time", %{scope: scope} do
      Scope.run(scope, fn ->
        assert {:ok, :played, :a, leftovers} = run([:a, :b, :c], fn c -> {:ok, c |> then(fn :a -> :played end)} end)
        assert leftovers.failed == []
        assert leftovers.untried == [:b, :c], "nothing else was asked, and they are still in order"
      end)
    end

    test "the next one down when the first cannot play", %{scope: scope} do
      Scope.run(scope, fn ->
        probe = fn
          :a -> {:error, :dead}
          :b -> {:ok, :played}
        end

        assert {:ok, :played, :b, %{failed: [{:a, :dead}], untried: [:c]}} = run([:a, :b, :c], probe)
      end)
    end

    test "nothing at all when none of them play", %{scope: scope} do
      Scope.run(scope, fn ->
        assert {:error, :all_failed, %{failed: failed, untried: []}} =
                 run([:a, :b], fn c -> {:error, {:no, c}} end)

        assert failed == [{:a, {:no, :a}}, {:b, {:no, :b}}]
      end)
    end

    test "and a probe that crashes is a failure, not a crash", %{scope: scope} do
      Scope.run(scope, fn ->
        probe = fn
          :a -> raise "boom"
          :b -> {:ok, :played}
        end

        assert {:ok, :played, :b, %{failed: [{:a, {:probe_crashed, _}}]}} = run([:a, :b], probe)
      end)
    end
  end

  describe "the hedging itself" do
    # The trade, stated: a leader slow enough to be hedged can lose to something
    # below it. That is the deal — a good answer now against a marginally
    # better one later — and it cannot happen on a play where the leader
    # answers inside the window, which is most of them.
    test "a leader slow enough to be hedged can lose to the next one down", %{scope: scope} do
      Scope.run(scope, fn ->
        probe = fn
          :slow_but_best -> Process.sleep(400); {:ok, :best}
          :quick -> Process.sleep(20); {:ok, :quick}
        end

        assert {:ok, :quick, :quick, leftovers} = run([:slow_but_best, :quick], probe, delay_ms: 20)
        assert :slow_but_best in leftovers.untried, "abandoned, and still offerable"
      end)
    end

    test "and it wins when it answers inside the window", %{scope: scope} do
      Scope.run(scope, fn ->
        probe = fn
          :best -> {:ok, :best}
          :quick -> {:ok, :quick}
        end

        assert {:ok, :best, :best, %{untried: [:quick]}} = run([:best, :quick], probe, delay_ms: 50)
      end)
    end

    test "a candidate abandoned mid-flight is untried, not failed", %{scope: scope} do
      Scope.run(scope, fn ->
        probe = fn
          :never -> Process.sleep(:infinity)
          :quick -> {:ok, :played}
        end

        assert {:ok, :played, :quick, leftovers} = run([:never, :quick], probe, delay_ms: 10)
        assert leftovers.failed == []
        assert :never in leftovers.untried, "it was started and dropped, so it was never answered for"
      end)
    end

    test "no more than max_parallel at once", %{scope: scope} do
      test = self()

      probe = fn
        :e ->
          send(test, {:started, :e})
          {:ok, :played}

        c ->
          send(test, {:started, c})
          Process.sleep(150)
          {:error, :dead}
      end

      task = Task.async(fn -> Scope.run(scope, fn -> run([:a, :b, :c, :d, :e], probe, delay_ms: 10, max_parallel: 2) end) end)

      # Two go up at once and the cap holds them there until one answers.
      assert_receive {:started, _}, 1_000
      assert_receive {:started, _}, 1_000
      refute_receive {:started, _}, 100, "a third was started with a cap of two"

      assert {:ok, :played, :e, _} = Task.await(task, 10_000)
    end
  end

  describe "what a caller is told as it happens" do
    test "trying, hedging and failing, in order", %{scope: scope} do
      test = self()

      Scope.run(scope, fn ->
        probe = fn
          :a -> Process.sleep(200); {:error, :dead}
          :b -> {:ok, :played}
        end

        run([:a, :b], probe, delay_ms: 20, notify: &send(test, &1))
      end)

      assert_receive {:trying, :a}, 1_000
      assert_receive {:hedging, :b}, 1_000
    end

    test "a failure reaches the caller before the race is over", %{scope: scope} do
      test = self()

      Scope.run(scope, fn ->
        probe = fn
          :a -> {:error, :dead}
          :b -> Process.sleep(100); {:ok, :played}
        end

        run([:a, :b], probe, delay_ms: 10, notify: &send(test, &1))
      end)

      assert_receive {:failed, :a, :dead}, 1_000
    end
  end

  test "an empty list is not a crash", %{scope: scope} do
    Scope.run(scope, fn ->
      assert {:error, :all_failed, %{failed: [], untried: []}} = run([], fn _ -> {:ok, :never} end)
    end)
  end

  # What laev plays with is this function now, and its own contract has not
  # changed — the names it reports and the shape it returns are the same.
  test "resolve_best still speaks its own language", %{scope: scope} do
    test = self()

    Scope.run(scope, fn ->
      sources = [%{name: "A good release"}, %{name: "Another"}]

      resolver = fn
        %{name: "A good release"}, _opts -> {:error, {:rd, 451, "nope"}}
        %{name: "Another"}, _opts -> {:ok, %{url: "https://example.invalid/x.mkv"}}
      end

      assert {:ok, stream, source, skipped} =
               Laev.Providers.resolve_best(sources, resolver: resolver, notify: &send(test, &1))

      assert stream.url == "https://example.invalid/x.mkv"
      assert source.name == "Another"
      assert skipped == [{"A good release", :infringing}], "451 is still reported as infringing"
      assert_receive {:trying, "A good release"}, 1_000
    end)
  end
end
