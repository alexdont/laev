defmodule Laev.RDFootprintTest do
  use ExUnit.Case, async: false

  alias Laev.RD
  alias Laev.RD.{Cache, Ledger, Sweep}
  alias Laev.Scope

  # Resolving a source costs five Real-Debrid calls and cannot cost fewer: add
  # the magnet, read the files, select one, wait for the link, unrestrict it.
  # The endpoint that answered "is this hash cached?" for a page at once is
  # gone — `403 disabled_endpoint`. So the waste was never the call count. It
  # was what each call leaves behind: measured on a real account, a hundred
  # torrents in twelve hours, five to thirteen per title watched, four stuck
  # converting and three still downloading files nobody would watch.

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-rd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, scope: Scope.new(dir, %{})}
  end

  describe "a probe that is abandoned still cleans up (Ledger)" do
    setup %{dir: dir} do
      test = self()
      previous = Application.get_env(:laev, :rd_delete)
      Application.put_env(:laev, :rd_delete, fn id -> send(test, {:deleted, id}) end)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:laev, :rd_delete, previous),
          else: Application.delete_env(:laev, :rd_delete)
      end)

      {:ok, scope: Scope.new(dir, %{})}
    end

    # The hedged race kills the losers where they stand, so the delete at the
    # end of `RD.resolve_magnet` never runs for them. This is what deletes
    # them instead.
    test "a claimant that dies has its torrent deleted", %{scope: scope} do
      probe = spawn(fn -> Scope.run(scope, fn -> Ledger.claim("ABANDONED1") end) end)
      ref = Process.monitor(probe)
      assert_receive {:DOWN, ^ref, :process, ^probe, _}, 1_000

      assert_receive {:deleted, "ABANDONED1"}, 2_000
    end

    # A probe that resolved keeps its torrent: it is either playing or on the
    # picker's page, where switching to it must not need a second resolve.
    test "a claim released is left alone", %{scope: scope} do
      probe =
        spawn(fn ->
          Scope.run(scope, fn ->
            Ledger.claim("RESOLVED1")
            Ledger.keep("RESOLVED1")
          end)
        end)

      ref = Process.monitor(probe)
      assert_receive {:DOWN, ^ref, :process, ^probe, _}, 1_000

      refute_receive {:deleted, "RESOLVED1"}, 500
    end

    # Monitors die with the VM. What the ledger wrote down is how the next run
    # knows what the last one left behind.
    test "an abandoned claim is on disk for the next run to find", %{scope: scope} do
      probe = spawn(fn -> Scope.run(scope, fn -> Ledger.claim("ONDISK1") end) end)
      ref = Process.monitor(probe)
      assert_receive {:DOWN, ^ref, :process, ^probe, _}, 1_000
      assert_receive {:deleted, "ONDISK1"}, 2_000

      # Deleted, so settled: the file is only for claims still outstanding.
      # The delete and the settling are separate steps, so give it a moment.
      Scope.run(scope, fn ->
        assert eventually(fn -> Ledger.abandoned() == [] end),
               "a torrent that was deleted should not stay on the list of what to delete"
      end)
    end
  end

  describe "a link resolved once is not resolved again (Cache)" do
    @stream %{
      url: "https://example.invalid/d/ABC/file.mkv",
      download_url: "https://example.invalid/d/ABC/file.mkv",
      filename: "file.mkv",
      filesize: 1_458_381_821,
      id: "ABC",
      streamable: true,
      hls: false
    }

    test "what was stored comes back when the link still serves it", %{scope: scope} do
      Scope.run(scope, fn ->
        assert Cache.put("A1B2", 1, 3, @stream) == :ok

        assert {:ok, stream} = Cache.get("A1B2", 1, 3, alive?: fn _url, _size -> true end)
        assert stream.url == @stream.url
        assert stream.filename == "file.mkv"
        assert stream.filesize == 1_458_381_821
        assert stream.id == "ABC"
      end)
    end

    test "and it is keyed per episode, not per source", %{scope: scope} do
      Scope.run(scope, fn ->
        Cache.put("A1B2", 1, 3, @stream)

        assert Cache.get("A1B2", 1, 4, alive?: fn _u, _s -> true end) == :miss,
               "episode four is a different file in the same pack"

        assert Cache.get("OTHER", 1, 3, alive?: fn _u, _s -> true end) == :miss
      end)
    end

    # The player is detached: a link that has expired fails where laev can no
    # longer retry. So a stored link that no longer serves the file is a miss,
    # and the caller resolves from scratch exactly as it did before.
    test "a link that no longer serves the file is a miss, and is dropped", %{scope: scope} do
      Scope.run(scope, fn ->
        Cache.put("DEAD1", nil, nil, @stream)

        assert Cache.get("DEAD1", nil, nil, alive?: fn _u, _s -> false end) == :miss
        assert Cache.get("DEAD1", nil, nil, alive?: fn _u, _s -> true end) == :miss,
               "a dead entry is deleted, not left to be asked about again"
      end)
    end

    test "nothing stored is a miss, not a crash", %{scope: scope} do
      Scope.run(scope, fn ->
        assert Cache.get("NEVERSEEN", 2, 2, alive?: fn _u, _s -> true end) == :miss
      end)
    end

    # Measured against a live link, the same link with a nonsense filename,
    # and one with a nonsense id:
    #
    #   live            -> 200  content-length 1458381821
    #   wrong filename  -> 200  content-length 1458381821
    #   wrong id        -> 404  content-length 2144  text/html
    #
    # So the length is what separates them, and the status alone does not.
    test "liveness is the length served, not the status code" do
      assert Cache.serves?(%{"content-length" => ["1458381821"]}, 1_458_381_821)
      refute Cache.serves?(%{"content-length" => ["2144"]}, 1_458_381_821),
             "a 404's error page is not the film"

      refute Cache.serves?(%{}, 1_458_381_821), "no length offered, no trust"
      assert Cache.serves?(%{"content-length" => ["2144"]}, nil), "nothing stored to compare"
    end

    test "the cache can be turned off", %{scope: scope} do
      Scope.run(scope, fn ->
        Cache.put("OFF1", nil, nil, @stream)

        Scope.with_overrides(%{rd_link_cache: "off"}, fn ->
          assert Cache.get("OFF1", nil, nil, alive?: fn _u, _s -> true end) == :miss
        end)
      end)
    end
  end

  describe "the sweep is narrow about what it deletes (Sweep)" do
    @none MapSet.new()

    test "strays go" do
      assert Sweep.reason(torrent(status: "error"), [], @none) == :error

      assert Sweep.reason(torrent(status: "magnet_conversion", age: 3600), [], @none) ==
               :never_converted

      assert Sweep.reason(torrent(status: "downloading", id: "X1"), ["X1"], @none) ==
               :abandoned_download
    end

    test "what is cached is never touched" do
      assert Sweep.reason(torrent(status: "downloaded"), [], @none) == nil

      assert Sweep.reason(torrent(status: "downloaded", id: "X1"), ["X1"], @none) == nil,
             "a claim never released is still not a reason to delete a cached torrent"
    end

    # A probe that is still running has a torrent that is still converting.
    test "a conversion that only just started is left to finish" do
      assert Sweep.reason(torrent(status: "magnet_conversion", age: 5), [], @none) == nil
    end

    # From here, a download you started looks exactly like one laev abandoned.
    # Only laev's own record of abandoning it tells them apart.
    test "a download nobody abandoned is somebody waiting on it" do
      assert Sweep.reason(torrent(status: "downloading", id: "MINE"), [], @none) == nil
      assert Sweep.reason(torrent(status: "queued", id: "MINE"), [], @none) == nil
    end

    test "and the history is protected whatever state it is in" do
      protected = MapSet.new(["abc123"])

      assert Sweep.reason(torrent(status: "error", hash: "ABC123"), [], protected) == nil,
             "hashes are compared without case"

      assert Sweep.reason(torrent(status: "downloading", id: "X1", hash: "abc123"), ["X1"], protected) == nil
    end

    # The launch sweep deletes torrents from a real account. A test run is not
    # a launch, and starting the app in one must reach nobody's account.
    test "and starting the app in a test never sweeps" do
      assert Application.get_env(:laev, :sweep_on_boot) == false
      assert Sweep.warm() == :ok
    end

    defp torrent(opts) do
      age = Keyword.get(opts, :age, 0)

      %{
        "id" => Keyword.get(opts, :id, "ID1"),
        "hash" => Keyword.get(opts, :hash, "f0f0f0"),
        "status" => Keyword.fetch!(opts, :status),
        "filename" => "something.mkv",
        "added" => DateTime.utc_now() |> DateTime.add(-age, :second) |> DateTime.to_iso8601()
      }
    end
  end

  describe "waiting on the provider costs fewer requests (backoff)" do
    # The window is the promise: a source that takes its time still gets the
    # same number of seconds it always got. Only the number of times laev asks
    # within it changes.
    test "the same window, a third fewer requests" do
      plan = RD.poll_plan(10_000)

      assert Enum.sum(plan) == 10_000, "the window is spent, not shortened"
      # One look, then one after each wait. Ten one-second attempts was the
      # old cost of waiting out a source that never came up.
      assert length(plan) + 1 == 7
    end

    # Not a free win: a coarser answer late in the window is the price of
    # asking fewer times. This is the half that is cheaper.
    test "the first wait is shorter than a second" do
      assert [first | _] = RD.poll_plan(10_000)
      assert first < 1_000
    end

    # The probe path's window. The count is unchanged here — five seconds was
    # already cheap — and the test says so rather than implying a saving.
    test "a five second window costs what it always did" do
      assert length(RD.poll_plan(5_000)) + 1 == 5
    end

    test "a short window is still spent exactly" do
      assert Enum.sum(RD.poll_plan(5_000)) == 5_000
      assert RD.poll_plan(0) == []
    end

    test "and no single wait grows past a few seconds" do
      assert Enum.max(RD.poll_plan(120_000)) <= 3_000
    end
  end

  describe "the infohash a magnet carries" do
    test "is what the cache and the blocklist are keyed by" do
      assert RD.hash_of("magnet:?xt=urn:btih:" <> String.duplicate("AB", 20) <> "&dn=x") ==
               String.duplicate("ab", 20)

      assert RD.hash_of("magnet:?dn=no-hash-here") == nil
      assert RD.hash_of(nil) == nil
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
