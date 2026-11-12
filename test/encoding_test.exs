defmodule Laev.EncodingTest do
  use ExUnit.Case, async: true

  alias Laev.{Encoding, Subtitles}

  # A subtitle file says nothing about its own encoding, and read as the wrong
  # one it does not fail — it comes out as a wall of mojibake that looks like a
  # laev bug. Laev read anything that was not valid UTF-8 as Latin-1: right for
  # the French releases it was written for, wrong for every Shift-JIS anime
  # release, Windows-1251 Russian fansub and GBK Chinese one.
  #
  # The fixtures are the real thing — "こんにちは、世界。字幕です。" and friends
  # put through iconv — carried as base64 so these tests need no iconv to run
  # the detection half.

  @japanese "こんにちは、世界。字幕です。"
  @russian "Привет, мир! Это субтитры."
  @french "Voilà, c'était déjà prêt — à côté."
  @latin1_french "Voilà, c'était déjà prêt."
  @chinese "你好，世界。这是字幕。"

  @fixtures %{
    cp932: {"grGC8YLJgr+CzYFBkKKKRYFCjpqWi4LFgreBQg==", @japanese},
    euc_jp: {"pLOk86TLpMGkz6GiwKSzpqGju/rL66THpLmhow==", @japanese},
    cp1251: {"z/Do4uXyLCDs6PAhIN3y7iDx8+Hy6PLw+y4=", @russian},
    cp1252: {"Vm9pbOAsIGMn6XRhaXQgZOlq4CBwcup0IJcg4CBj9HTpLg==", @french},
    latin1: {"Vm9pbOAsIGMn6XRhaXQgZOlq4CBwcup0Lg==", @latin1_french},
    gbk: {"xOO6w6OsysC956Gj1eLKx9fWxLuhow==", @chinese}
  }

  defp bytes(encoding), do: @fixtures |> Map.fetch!(encoding) |> elem(0) |> Base.decode64!()
  defp text(encoding), do: @fixtures |> Map.fetch!(encoding) |> elem(1)

  describe "what it says a file is" do
    test "a byte-order mark is not a guess" do
      assert Encoding.detect(:unicode.characters_to_binary("WEBVTT", :utf8, {:utf16, :little})) ==
               {:utf16, :little}

      assert Encoding.detect(<<0xFE, 0xFF, 0, ?W, 0, ?E>>) == {:utf16, :big}
      assert Encoding.detect(<<0xEF, 0xBB, 0xBF, "WEBVTT">>) == :utf8
    end

    # Subtitle files written by Windows tools are often UTF-16 with no mark at
    # all; ASCII in UTF-16 is every other byte a NUL, which is unmistakable.
    test "UTF-16 with no mark, from the NULs" do
      little = :unicode.characters_to_binary("00:00:01,000 --> 00:00:04,000", :utf8, {:utf16, :little})
      big = :unicode.characters_to_binary("00:00:01,000 --> 00:00:04,000", :utf8, {:utf16, :big})

      assert Encoding.detect(little) == {:utf16, :little}
      assert Encoding.detect(big) == {:utf16, :big}
    end

    test "UTF-8 is recognised as itself, mark or no mark" do
      assert Encoding.detect("Hello, " <> @japanese) == :utf8
      assert Encoding.detect("plain ascii only") == :utf8
      assert Encoding.detect("") == :utf8
    end

    test "each code page is told from the others by its bytes" do
      for encoding <- Map.keys(@fixtures) do
        assert Encoding.detect(bytes(encoding)) == encoding,
               "#{encoding} was read as #{inspect(Encoding.detect(bytes(encoding)))}"
      end
    end

    # The two that structure cannot separate: both are pairs of 0xA1..0xFE, so
    # the kana rows are the only evidence there is.
    test "EUC-JP and GBK, which have the same shape" do
      assert Encoding.detect(bytes(:euc_jp)) == :euc_jp
      assert Encoding.detect(bytes(:gbk)) == :gbk
    end

    # 0x80..0x9F is a control character in Latin-1 and a printable one in
    # Windows-1252, so an em dash is what tells them apart.
    test "Windows-1252 only where Latin-1 could not hold it" do
      assert Encoding.detect(bytes(:cp1252)) == :cp1252
      assert Encoding.detect(bytes(:latin1)) == :latin1
    end
  end

  describe "the text it gives back" do
    @describetag :iconv

    setup do
      unless System.find_executable("iconv"), do: raise("iconv is needed for these tests")
      :ok
    end

    test "every encoding comes back as the words that were written" do
      for encoding <- Map.keys(@fixtures) do
        assert Encoding.to_utf8(bytes(encoding)) == text(encoding),
               "#{encoding} did not decode to what was encoded"
      end
    end

    test "and a subtitle file converts with its words intact" do
      srt = "1\n00:00:01,000 --> 00:00:04,000\n" <> @japanese <> "\n"
      {shift_jis, 0} = encode(srt, "CP932")

      vtt = Subtitles.to_vtt("anime.srt", shift_jis)

      assert String.starts_with?(vtt, "WEBVTT")
      assert vtt =~ @japanese
      assert vtt =~ "00:00:01.000 --> 00:00:04.000", "and the timestamps are still WebVTT's"
    end

    defp encode(text, to) do
      path = Path.join(System.tmp_dir!(), "laev-enc-test-#{System.unique_integer([:positive])}")
      File.write!(path, text)
      result = System.cmd("iconv", ["-f", "UTF-8", "-t", to, path])
      File.rm(path)
      result
    end
  end

  describe "what it never does" do
    test "raise, whatever the bytes are" do
      for bad <- [<<0xFF, 0xFE>>, <<0x80, 0x81, 0x82>>, <<0xC3>>, <<0>>, "", <<0xFF>>] do
        assert is_binary(Encoding.to_utf8(bad)), "#{inspect(bad)} brought it down"
      end
    end

    test "lose the ASCII in a file it cannot place" do
      # Bytes that fit nothing: the words around them must survive.
      assert Encoding.to_utf8(<<"00:00:01,000 ", 0x81, 0x20, " --> end">>) =~ "00:00:01,000"
    end

    test "or change a file that is already UTF-8" do
      text = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\n" <> @japanese
      assert Encoding.to_utf8(text) == text
    end
  end
end
