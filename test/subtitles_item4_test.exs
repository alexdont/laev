defmodule Laev.SubtitlesItem4Test do
  use ExUnit.Case, async: false

  alias Laev.{OpenSubtitles, Scope, Settings, Subtitles}

  describe "reading whatever encoding a subtitle file arrived in" do
    # French and other Western European releases ship Latin-1, which arrives as
    # mojibake or nothing at all when read as UTF-8.
    test "a Latin-1 file keeps its accents" do
      latin1 = :unicode.characters_to_binary("Voilà, c'est déjà fini", :utf8, :latin1)

      refute String.valid?(latin1), "the fixture really is not UTF-8"
      assert Subtitles.to_utf8(latin1) == "Voilà, c'est déjà fini"
    end

    test "UTF-16 with either byte order is read" do
      for endianness <- [:little, :big] do
        bom = if endianness == :little, do: <<0xFF, 0xFE>>, else: <<0xFE, 0xFF>>
        bytes = bom <> :unicode.characters_to_binary("ざ", :utf8, {:utf16, endianness})

        assert Subtitles.to_utf8(bytes) == "ざ"
      end
    end

    test "a UTF-8 byte-order mark is dropped, valid UTF-8 left alone" do
      assert Subtitles.to_utf8(<<0xEF, 0xBB, 0xBF>> <> "hello") == "hello"
      assert Subtitles.to_utf8("déjà") == "déjà"
    end

    test "something already WebVTT is passed through untouched" do
      vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n"
      assert Subtitles.to_vtt("whatever.srt", vtt) == vtt
    end

    test ".ssa is read as ASS, not as SubRip" do
      ssa = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Text\n"
      assert Subtitles.to_vtt("x.ssa", ssa) =~ "WEBVTT"
    end
  end

  describe "the OpenSubtitles login, which searching does not need" do
    test "it says which of the two things is missing" do
      no_key = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: nil})
      key_only = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: "k", opensubtitles_username: nil, opensubtitles_password: nil})

      assert Scope.run(no_key, fn -> OpenSubtitles.state() end) == :off
      assert Scope.run(key_only, fn -> OpenSubtitles.state() end) == :search
    end

    # 400 from the service means an email was given where a username was
    # wanted, which is the commonest mistake and unguessable from the raw reply.
    test "an email address is refused with the reason, before the service is asked" do
      scope = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: "k"})

      assert Scope.run(scope, fn -> OpenSubtitles.verify_login("me@example.com", "pw") end) ==
               {:error, "OpenSubtitles wants your username, not your email address"}
    end

    test "half a login is not a login" do
      scope = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: "k"})

      assert {:error, "enter both the username and the password"} =
               Scope.run(scope, fn -> OpenSubtitles.verify_login("someone", "") end)
    end

    test "without an API key there is nothing to log in to" do
      scope = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: nil})

      assert {:error, "add the OpenSubtitles API key first"} =
               Scope.run(scope, fn -> OpenSubtitles.verify_login("someone", "pw") end)
    end
  end

  describe "the login as a managed setting" do
    # They were in the config all along and were not settings, so nothing with a
    # form could manage them — and nothing said why downloads came back empty.
    test "username and password are settings now" do
      keys = Enum.map(Settings.all(), & &1.key)

      assert "OPENSUBTITLES_USERNAME" in keys
      assert "OPENSUBTITLES_PASSWORD" in keys
    end

    test "the password is a secret and comes back masked" do
      scope = Scope.new(System.tmp_dir!(), %{opensubtitles_password: "hunter2hunter2"})

      Scope.run(scope, fn ->
        field = Enum.find(Settings.all(), &(&1.key == "OPENSUBTITLES_PASSWORD"))

        assert field.type == :secret
        assert field.set?
        refute field.value == "hunter2hunter2"
      end)
    end

    test "half a pair saves and says what is still needed" do
      scope = Scope.new(System.tmp_dir!(), %{opensubtitles_api_key: "k", opensubtitles_password: nil})

      Scope.run(scope, fn ->
        assert {:ok, detail} = Settings.validate("OPENSUBTITLES_USERNAME", "someone")
        assert detail =~ "both"
      end)
    end
  end
end
