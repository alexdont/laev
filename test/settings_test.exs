defmodule Laev.SettingsTest do
  use ExUnit.Case, async: false

  alias Laev.{Scope, Settings}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{rd_token: "a-very-secret-token-value", player: "mpv"})}
  end

  test "every setting describes itself well enough to render a form" do
    for option <- Settings.all() do
      assert is_binary(option.key) and is_binary(option.label)
      assert option.group in [:playback, :language, :appearance, :files, :keys]
      assert match?({:one_of, _}, option.type) or option.type in [:text, :secret]
      assert Map.has_key?(option, :set?)
    end

    assert Map.has_key?(Settings.groups(), :playback)
  end

  # A settings page has no reason to put somebody's debrid token back on the
  # wire; whether it is set, and which one it is, is what it actually asks.
  test "a secret comes back masked, never whole", %{scope: scope} do
    Scope.run(scope, fn ->
      token = Enum.find(Settings.all(), &(&1.key == "RD_TOKEN"))

      assert token.set?
      refute token.value == "a-very-secret-token-value"
      assert token.value =~ "•"
      assert Settings.get("RD_TOKEN") == "a-very-secret-token-value", "the code that uses it still gets it"
    end)
  end

  test "a change applies at once, to that user only", %{scope: scope} do
    other = Scope.new(Path.join(scope.dir, "other"), %{player: "mpv"})

    Scope.run(scope, fn ->
      assert Settings.put("LAEV_PLAYER", "vlc") == :ok
      assert Laev.Config.player() == "vlc"
    end)

    Scope.run(other, fn -> assert Laev.Config.player() == "mpv" end)
  end

  test "a setting refuses a value it does not accept", %{scope: scope} do
    Scope.run(scope, fn ->
      assert {:error, {:must_be_one_of, "LAEV_PLAYER", _}} = Settings.put("LAEV_PLAYER", "iina")
      assert {:error, {:unknown_setting, "NONSENSE"}} = Settings.put("NONSENSE", "x")
      assert Laev.Config.player() == "mpv", "a refused change changes nothing"
    end)
  end

  test "it can say what is missing before anything is tried", %{scope: scope} do
    bare = Scope.new(scope.dir, %{rd_token: nil, torbox_api_key: nil, tmdb_key: nil})

    Scope.run(bare, fn ->
      missing = Settings.missing_essentials()
      assert "TMDB_API_KEY" in missing
      assert "RD_TOKEN" in missing
    end)

    with_debrid = Scope.new(scope.dir, %{rd_token: "x", tmdb_key: "y"})
    Scope.run(with_debrid, fn -> assert Settings.missing_essentials() == [] end)
  end
end
