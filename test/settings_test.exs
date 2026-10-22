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
      assert option.group in [:playback, :language, :appearance, :files, :keys, :sync]
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

  # A change that lived only until the end of the request would be a setting
  # that never saved — worse than one that cannot be changed at all.
  test "a user's change survives their next request", %{scope: scope} do
    Scope.run(scope, fn -> assert Settings.put("LAEV_PLAYER", "vlc") == :ok end)

    # A new request for the same user: built from what they saved, not from
    # whatever the last process happened to hold.
    fresh = Scope.load(scope.dir)
    assert Scope.run(fresh, fn -> Laev.Config.player() end) == "vlc"
    assert File.read!(Path.join(scope.dir, "config")) =~ "LAEV_PLAYER=vlc"
  end

  test "one user's settings are not another's", %{scope: scope} do
    other_dir = Path.join(scope.dir, "someone-else")
    File.mkdir_p!(other_dir)

    Scope.run(scope, fn -> Settings.put("LAEV_PLAYER", "vlc") end)
    Scope.run(Scope.load(other_dir), fn -> Settings.put("LAEV_PLAYER", "mpv") end)

    assert Scope.run(Scope.load(scope.dir), fn -> Laev.Config.player() end) == "vlc"
    assert Scope.run(Scope.load(other_dir), fn -> Laev.Config.player() end) == "mpv"
  end

  # What the server holds for somebody beats what is on their disk: a token
  # kept in a database is the authority on that token.
  test "what the caller passes in wins over the file", %{scope: scope} do
    Scope.run(scope, fn -> Settings.put("LAEV_PLAYER", "vlc") end)

    forced = Scope.load(scope.dir, %{player: "browser"})
    assert Scope.run(forced, fn -> Laev.Config.player() end) == "browser"
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
