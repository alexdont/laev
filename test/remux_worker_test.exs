defmodule Laev.RemuxWorkerTest do
  use ExUnit.Case, async: false

  alias Laev.Remux
  alias Laev.Remux.Worker

  # A worker holds its release's id in the registry, and `Remux.start/3` reuses
  # a registered id rather than starting a second ffmpeg. So a worker whose
  # ffmpeg *died* — killed, out of disk, a stream that went away — used to hold
  # that id for its whole two-hour TTL while serving a playlist that would
  # never grow another line. Every later play of that release waited and timed
  # out, and the note in roki was "restart the app or wait".

  @id String.duplicate("a", 16)

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, state: %{id: @id, url: "", dir: dir, port: :a_port, os_pid: nil, last_error: nil, subs: []}}
  end

  defp exited(state, status), do: Worker.handle_info({state.port, {:exit_status, status}}, state)

  describe "when ffmpeg exits" do
    test "having finished, the worker stays to serve what it wrote", %{dir: dir, state: state} do
      File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n")

      assert {:noreply, %{port: nil}} = exited(state, 0)
    end

    # The fix: without ENDLIST the conversion never finished, so the id has to
    # go back rather than be held for two hours.
    test "having died partway, the worker stops so the id is free", %{dir: dir, state: state} do
      File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n")

      assert {:stop, :normal, _state} = exited(state, 137)
    end

    test "having died before writing anything at all, likewise", %{state: state} do
      assert {:stop, :normal, _state} = exited(state, 1)
    end

    # A zero exit status is not the question — what ffmpeg left behind is.
    test "a clean exit with nothing finished is still nothing to serve", %{dir: dir, state: state} do
      File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n")

      assert {:stop, :normal, _state} = exited(state, 0)
    end

    # With switchable audio the media playlist is s_0.m3u8 beside the master,
    # which is the file `Remux.complete?/1` reads too.
    test "and the renditions case reads the right playlist", %{dir: dir, state: state} do
      File.write!(Path.join(dir, "master.m3u8"), "#EXTM3U\n")
      File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n#EXT-X-ENDLIST\n")
      File.write!(Path.join(dir, "s_0.m3u8"), "#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n")

      assert {:stop, :normal, _state} = exited(state, 0),
             "index.m3u8 having ENDLIST means nothing when the media playlist is s_0"
    end
  end

  describe "what counts as a cache" do
    test "a finished playlist does", %{} do
      File.mkdir_p!(Remux.dir(@id))
      File.write!(Path.join(Remux.dir(@id), "index.m3u8"), "#EXTM3U\n#EXT-X-ENDLIST\n")
      on_exit(fn -> File.rm_rf(Remux.dir(@id)) end)

      assert Remux.complete?(@id)
    end

    test "a partial one does not", %{} do
      File.mkdir_p!(Remux.dir(@id))
      File.write!(Path.join(Remux.dir(@id), "index.m3u8"), "#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n")
      on_exit(fn -> File.rm_rf(Remux.dir(@id)) end)

      refute Remux.complete?(@id)
    end

    test "and nothing at all does not", %{} do
      File.rm_rf(Remux.dir(@id))
      refute Remux.complete?(@id)
    end
  end
end
