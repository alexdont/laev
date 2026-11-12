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

  # Reported against 0.1.55: a short Latin-1 French subtitle was read as
  # Shift-JIS. "À bientôt" is `C0 20 62 69 65 6E 74 F4 74` — 0xC0 is a
  # half-width katakana single in Shift-JIS and `F4 74` is a valid lead/trail
  # pair, so the pair walk agreed with cp932 and it won before the single-byte
  # pages were ever considered. The file came out as "ﾀ bient", and roki had to
  # read such files as Western itself before laev saw them.
  describe "a Western page the pair walk would agree with" do
    @french_srt "1\n00:00:01,000 --> 00:00:03,500\nBonjour\n\n2\n00:00:04,000 --> 00:00:06,000\nÀ bientôt\n"

    defp as(text, encoding), do: :unicode.characters_to_binary(text, :utf8, encoding)

    test "the reported subtitle is Latin-1, not Shift-JIS" do
      assert Encoding.detect(as(@french_srt, :latin1)) == :latin1
    end

    test "and its words survive the conversion" do
      vtt = Subtitles.to_vtt("a.srt", as(@french_srt, :latin1))

      assert vtt =~ "À bientôt"
      assert vtt =~ "Bonjour"
      refute vtt =~ "ﾀ", "that is what reading it as Shift-JIS looked like"
    end

    # 0xC0 alone was the whole case for cp932, and half-width katakana as the
    # only evidence is not Japanese — real subtitles are double-byte kana.
    test "a lone accent in the katakana range is not Japanese" do
      for text <- ["À bientôt", "Dépêche-toi", "Grüße aus Köln", "¿Dónde está?"] do
        assert Encoding.detect(as(text, :latin1)) in [:latin1, :cp1252],
               "#{text} was read as #{inspect(Encoding.detect(as(text, :latin1)))}"
      end
    end

    test "and one with a 0x80..0x9F byte is still Windows-1252" do
      # The em dash is 0x97 there and a control character in Latin-1.
      assert Encoding.detect(<<"Voil", 0xE0, " ", 0x97, " fin">>) == :cp1252
    end

    # The other direction: high bytes that touch each other, which is what CJK
    # text is made of, must still reach the pair walk.
    test "a page of adjacent high bytes is not taken for Western" do
      assert Encoding.detect(bytes(:cp932)) == :cp932
      assert Encoding.detect(bytes(:euc_jp)) == :euc_jp
      assert Encoding.detect(bytes(:gbk)) == :gbk
      assert Encoding.detect(bytes(:cp1251)) == :cp1251, "Cyrillic words are runs of high bytes"
    end

    # A long Japanese subtitle file has ASCII timestamps through it, so the
    # ratio alone would not settle it — the adjacency is what does.
    test "Japanese among timestamps is still Japanese" do
      srt = "1\n00:00:01,000 --> 00:00:03,500\n" <> @japanese <> "\n"
      {shift_jis, 0} = encode(srt, "CP932")

      assert Encoding.detect(shift_jis) == :cp932
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
