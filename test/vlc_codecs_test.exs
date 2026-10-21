defmodule Laev.VlcCodecsTest do
  use ExUnit.Case, async: false

  alias Laev.Doctor

  # A VLC without libavcodec installs, opens a window, and then refuses the
  # file — "could not decode the format hevc" — which is most debrid releases
  # and nothing about it points at a missing package.
  test "a VLC with no libavcodec is reported as broken" do
    # A plugin directory that exists and holds everything *but* the decoders,
    # which is what `pacman -S vlc` leaves behind. Built here rather than read
    # off this machine, whose own VLC was fixed the moment this was written.
    dir = Path.join(System.tmp_dir!(), "vlc-bare-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "codec"))
    File.write!(Path.join([dir, "codec", "liba52_plugin.so"]), "")
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, detail} = Doctor.check_vlc_codecs([dir])
    assert detail =~ "libavcodec"
    assert detail =~ "vlc-plugin-ffmpeg", "it must say what to install"
  end

  # Nothing is claimed where the layout isn't the one being looked for — macOS
  # keeps its plugins inside the bundle, and a wrong warning is worse than none.
  test "an unknown layout claims nothing either way" do
    assert {:ok, detail} = Doctor.check_vlc_codecs(["/nonexistent/vlc/plugins"])
    assert detail =~ "not checked"
  end

  test "a VLC that has the plugin passes" do
    dir = Path.join(System.tmp_dir!(), "vlc-plugins-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "codec"))
    File.write!(Path.join([dir, "codec", "libavcodec_plugin.so"]), "")
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, detail} = Doctor.check_vlc_codecs([dir])
    assert detail =~ "h265"
  end
end
