defmodule Laev.RemuxGuardsTest do
  use ExUnit.Case, async: false

  alias Laev.{Playback, Remux}

  # Incident 2026-10-23: a French Lupin 4K H.265 release was played in a
  # browser. laev re-encoded it at source resolution with no speed preset, so
  # it never reached real time and took every core trying; four of them put the
  # host near a load average of 150.
  describe "what counts as an expensive release" do
    test "anything that is not h264 has to be re-encoded" do
      assert Playback.heavy?(%{codec: "h265"})
      assert Playback.heavy?(%{codec: "HEVC"})
      assert Playback.heavy?(%{codec: "av1"})
      refute Playback.heavy?(%{codec: "h264"})
      refute Playback.heavy?(%{codec: "x264"})
    end

    test "a source with nothing said about its codec is not assumed expensive" do
      refute Playback.heavy?(%{})
      refute Playback.heavy?(nil)
    end

    test "it reads a {source, stream} pair as well" do
      assert Playback.heavy?({%{codec: "h265"}, %{url: "x"}})
    end
  end

  describe "refusing what cannot keep up" do
    test "a 4K re-encode is refused before it starts" do
      assert Playback.allowed?(%{codec: "h265", resolution: "2160p"}) == {:error, :too_heavy}
      assert Playback.allowed?(%{codec: "h265", resolution: "4K"}) == {:error, :too_heavy}
    end

    test "the same release at 1080p is fine" do
      assert Playback.allowed?(%{codec: "h265", resolution: "1080p"}) == :ok
    end

    test "an h264 release is never refused, whatever its size" do
      assert Playback.allowed?(%{codec: "h264", resolution: "2160p"}) == :ok
    end

    test "a caller can raise the cap for a machine that can take it" do
      assert Playback.allowed?(%{codec: "h265", resolution: "2160p"}, max_height: 2160) == :ok
    end

    test "too many at once is a refusal, not a slower host" do
      assert Playback.allowed?(%{codec: "h265", resolution: "1080p"}, max_encoders: 0) ==
               {:error, :busy}
    end
  end

  describe "the idle reaper" do
    test "a conversion just seen is never cut short" do
      Remux.touch("abcdef0123456789")
      assert Remux.Reaper.last_touch("abcdef0123456789")

      # Nothing is running under that id, so a sweep is a no-op rather than an
      # error — the reaper must never be the thing that breaks playback.
      assert Remux.Reaper.sweep(0) == :ok
    end

    test "touching an id laev never heard of is harmless" do
      assert Remux.touch("not-a-real-id") == :ok
      assert Remux.touch(nil) == :ok
    end

    test "running/0 answers even with nothing running" do
      assert is_list(Remux.running())
    end
  end
end
