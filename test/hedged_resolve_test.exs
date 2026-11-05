defmodule Laev.HedgedResolveTest do
  use ExUnit.Case, async: false

  alias Laev.Providers

  defp source(name), do: %{name: name, hash: name, resolution: "1080p", source: "WEB", seeders: 9, size: 1}

  # A prober scripted per source name: {:ok | :fail, how long it takes}.
  defp prober(script, log) do
    fn source, _opts ->
      Agent.update(log, &[source.name | &1])
      {outcome, delay} = Map.fetch!(script, source.name)
      Process.sleep(delay)

      case outcome do
        :ok -> {:ok, %{url: "stream://#{source.name}"}}
        :fail -> {:error, :no_video_files}
      end
    end
  end

  defp run(sources, script, opts \\ []) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    result =
      Providers.resolve_best(
        sources,
        Keyword.merge([resolver: prober(script, log), hedge_after: 60, max_in_flight: 3], opts)
      )

    {result, Agent.get(log, &Enum.reverse(&1))}
  end

  describe "the common play: the best source answers" do
    # Eight of nine titles measured resolved on the first attempt. Nothing else
    # should be touched — that is the whole saving, six Real-Debrid requests
    # against forty-eight.
    test "only the first source is tried" do
      {{:ok, _stream, source, _skipped}, tried} =
        run([source("a"), source("b"), source("c")], %{"a" => {:ok, 5}, "b" => {:ok, 5}, "c" => {:ok, 5}})

      assert source.name == "a"
      assert tried == ["a"], "nothing else was asked for"
    end

    test "and it is the same source a whole page would have chosen" do
      # The page picks the head of what resolved, in rank order; so does this.
      {{:ok, _s, source, _}, _tried} =
        run([source("a"), source("b")], %{"a" => {:ok, 5}, "b" => {:ok, 5}})

      assert source.name == "a"
    end
  end

  describe "a source that fails" do
    test "the next one is tried, and the failure is reported" do
      {{:ok, _s, source, skipped}, tried} =
        run([source("a"), source("b")], %{"a" => {:fail, 5}, "b" => {:ok, 5}})

      assert source.name == "b"
      assert tried == ["a", "b"]
      assert skipped == [{"a", :no_video_files}]
    end

    test "everything failing says so rather than hanging" do
      {{:error, {:all_failed, skipped}}, tried} =
        run([source("a"), source("b")], %{"a" => {:fail, 5}, "b" => {:fail, 5}})

      assert length(skipped) == 2
      assert tried == ["a", "b"]
    end

    test "no sources at all is not a crash" do
      assert {:error, {:all_failed, []}} = Providers.resolve_best([], resolver: fn _, _ -> {:ok, %{}} end)
    end
  end

  describe "hedging, which is why this is not simply sequential" do
    # The title that prompted it: two sources failed in 1.5s and 1.3s and the
    # third hung for 11.8s — fifteen seconds of nothing, served one at a time.
    test "a slow leader does not hold up the queue" do
      {{:ok, _s, source, _}, tried} =
        run([source("slow"), source("quick")], %{"slow" => {:ok, 5_000}, "quick" => {:ok, 10}})

      assert source.name == "quick", "the one that answered"
      assert tried == ["slow", "quick"], "and the leader was started first"
    end

    test "the cap on how many run at once is honoured" do
      script = Map.new(["a", "b", "c", "d", "e"], &{&1, {:ok, 3_000}})
      sources = Enum.map(["a", "b", "c", "d", "e"], &source/1)

      {:ok, log} = Agent.start_link(fn -> [] end)

      task =
        Task.async(fn ->
          Providers.resolve_best(sources,
            resolver: prober(script, log),
            hedge_after: 20,
            max_in_flight: 2
          )
        end)

      Process.sleep(300)
      in_flight = Agent.get(log, &length/1)
      Task.shutdown(task, :brutal_kill)

      assert in_flight == 2, "two at once, not five — got #{in_flight}"
    end

    # Rank order is kept among those that have actually answered, so a hedge
    # finishing first does not promote a worse release when the better one is
    # also ready.
    test "when two answer together the better-ranked one wins" do
      {{:ok, _s, source, _}, _tried} =
        run([source("best"), source("other")], %{"best" => {:ok, 80}, "other" => {:ok, 80}}, hedge_after: 10)

      assert source.name == "best"
    end
  end

  describe "what the caller is told" do
    test "it says what it is trying, and what it gave up on" do
      {:ok, said} = Agent.start_link(fn -> [] end)
      {:ok, log} = Agent.start_link(fn -> [] end)

      Providers.resolve_best(
        [source("a"), source("b")],
        resolver: prober(%{"a" => {:fail, 5}, "b" => {:ok, 5}}, log),
        hedge_after: 60,
        notify: fn message -> Agent.update(said, &[message | &1]) end
      )

      messages = Agent.get(said, &Enum.reverse(&1))

      assert {:trying, "a"} in messages
      assert {:skipped, "a", :no_video_files} in messages
      assert {:trying, "b"} in messages
    end

    test "a hedge is announced, so two at once is not a mystery" do
      {:ok, said} = Agent.start_link(fn -> [] end)
      {:ok, log} = Agent.start_link(fn -> [] end)

      Providers.resolve_best(
        [source("slow"), source("quick")],
        resolver: prober(%{"slow" => {:ok, 2_000}, "quick" => {:ok, 10}}, log),
        hedge_after: 30,
        notify: fn message -> Agent.update(said, &[message | &1]) end
      )

      assert {:hedging, "quick"} in Agent.get(said, &Enum.reverse(&1))
    end
  end
end
