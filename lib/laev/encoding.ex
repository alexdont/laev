defmodule Laev.Encoding do
  @moduledoc """
  What a text file is encoded in, decided from its bytes, and its text in UTF-8.

  Subtitle files carry no encoding declaration. Most are UTF-8, many Western
  European ones are Latin-1 or Windows-1252, and a great many anime releases
  are Shift-JIS — plus Windows-1251 for Russian fansubs and GBK for Chinese
  ones. Read as the wrong one they do not fail: they come out as mojibake, a
  wall of `ã‚ã‚Š` that looks like a laev bug rather than an encoding one.

  Laev used to read anything that was not valid UTF-8 as Latin-1, which is
  right for the French releases it was written for and wrong for every CJK one.

  ## How the guess is made

  In order, stopping at the first that holds:

    1. A byte-order mark — UTF-8, UTF-16 either way round.
    2. UTF-16 with no mark, from the NUL bytes every second position that ASCII
       text in UTF-16 is full of.
    3. Valid UTF-8, which is nearly everything and costs one pass to be sure of.
    4. A multi-byte encoding whose structure the high bytes actually fit:
       Shift-JIS, EUC-JP or GBK. A file that parses cleanly as exactly one of
       them is that one.
    5. A single-byte encoding, from how the high bytes sit: in runs (a Cyrillic
       word is all high bytes) or alone between ASCII (a French accent).

  Nothing here is certain — there is no certainty to be had, a short file of
  high bytes can be valid in all of them — so the order runs from the evidence
  that cannot be argued with to the heuristics, and `detect/1` says which it
  landed on so a caller can log it.

  ## Decoding

  UTF-8, UTF-16 and Latin-1 are decoded here, by OTP. The code pages need
  mapping tables OTP has not got, so `to_utf8/1` shells out to `iconv`, the way
  laev shells out to mpv and ffmpeg — no NIF to compile, nothing to configure,
  and present on every Linux and macOS laev runs on. Where it is missing or
  refuses the bytes, the result is the Latin-1 reading, which is what laev did
  with all of them before.
  """

  @type encoding ::
          :utf8
          | {:utf16, :little | :big}
          | :cp932
          | :euc_jp
          | :gbk
          | :cp1251
          | :cp1252
          | :latin1

  # Enough to judge by without reading a 10MB file to the end.
  @sample 64 * 1024

  @iconv %{cp932: "CP932", euc_jp: "EUC-JP", gbk: "GBK", cp1251: "CP1251", cp1252: "CP1252"}

  @doc """
  The encoding of `binary`, as the atom (or `{:utf16, endianness}` tuple) that
  `to_utf8/1` would decode it with.
  """
  @spec detect(binary) :: encoding
  def detect(<<0xFF, 0xFE, _rest::binary>>), do: {:utf16, :little}
  def detect(<<0xFE, 0xFF, _rest::binary>>), do: {:utf16, :big}
  def detect(<<0xEF, 0xBB, 0xBF, _rest::binary>>), do: :utf8

  def detect(binary) when is_binary(binary) do
    sample = binary_part(binary, 0, min(byte_size(binary), @sample))

    cond do
      utf16 = unmarked_utf16(sample) -> utf16
      String.valid?(sample) -> :utf8
      true -> guess(sample)
    end
  end

  def detect(_other), do: :utf8

  @doc """
  `binary` as UTF-8, whatever it was encoded in. Never raises: text that cannot
  be decoded comes back read as Latin-1, which at least keeps its ASCII.
  """
  @spec to_utf8(binary) :: binary
  def to_utf8(<<0xFF, 0xFE, rest::binary>>), do: utf16(rest, :little)
  def to_utf8(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest, :big)
  def to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: to_utf8(rest)

  def to_utf8(binary) when is_binary(binary) do
    case detect(binary) do
      :utf8 -> binary
      {:utf16, endianness} -> utf16(binary, endianness)
      :latin1 -> latin1(binary)
      code_page -> iconv(binary, Map.fetch!(@iconv, code_page))
    end
  end

  def to_utf8(other), do: other

  # ── UTF-16 without a mark ─────────────────────────────────────────

  # ASCII in UTF-16 is every other byte a NUL, and which half tells you the
  # endianness. Anything less lopsided than nine to one is not UTF-16 text.
  defp unmarked_utf16(sample) do
    bytes = :binary.bin_to_list(binary_part(sample, 0, min(byte_size(sample), 2_048)))
    {evens, odds} = bytes |> Enum.with_index() |> Enum.split_with(fn {_b, i} -> rem(i, 2) == 0 end)

    even_nuls = Enum.count(evens, fn {b, _i} -> b == 0 end)
    odd_nuls = Enum.count(odds, fn {b, _i} -> b == 0 end)
    total = max(length(evens), 1)

    cond do
      odd_nuls > total * 0.4 and even_nuls <= total * 0.05 -> {:utf16, :little}
      even_nuls > total * 0.4 and odd_nuls <= total * 0.05 -> {:utf16, :big}
      true -> nil
    end
  end

  # ── the guess ─────────────────────────────────────────────────────

  defp guess(sample) do
    fits = Enum.filter([:cp932, :euc_jp, :gbk], &fits?(&1, sample))

    case fits do
      [one] -> one
      [] -> single_byte(sample)
      several -> among(several, sample)
    end
  end

  # Whether every high byte in the sample is part of a well-formed sequence of
  # this encoding. One byte out of place rules it out, which is what makes this
  # worth more than counting bytes.
  defp fits?(encoding, sample), do: walk(encoding, sample, 0)

  defp walk(_encoding, <<>>, pairs), do: pairs > 0
  defp walk(encoding, <<byte, rest::binary>>, pairs) when byte < 0x80, do: walk(encoding, rest, pairs)

  defp walk(:cp932, <<byte, rest::binary>>, pairs) when byte in 0xA1..0xDF,
    do: walk(:cp932, rest, pairs + 1)

  defp walk(:cp932, <<lead, trail, rest::binary>>, pairs)
       when lead in 0x81..0x9F or lead in 0xE0..0xFC do
    if trail in 0x40..0x7E or trail in 0x80..0xFC, do: walk(:cp932, rest, pairs + 1), else: false
  end

  defp walk(:euc_jp, <<0x8E, trail, rest::binary>>, pairs) when trail in 0xA1..0xDF,
    do: walk(:euc_jp, rest, pairs + 1)

  defp walk(:euc_jp, <<0x8F, lead, trail, rest::binary>>, pairs)
       when lead in 0xA1..0xFE and trail in 0xA1..0xFE,
       do: walk(:euc_jp, rest, pairs + 1)

  defp walk(:euc_jp, <<lead, trail, rest::binary>>, pairs) when lead in 0xA1..0xFE do
    if trail in 0xA1..0xFE, do: walk(:euc_jp, rest, pairs + 1), else: false
  end

  defp walk(:gbk, <<lead, trail, rest::binary>>, pairs) when lead in 0x81..0xFE do
    if trail in 0x40..0xFE and trail != 0x7F, do: walk(:gbk, rest, pairs + 1), else: false
  end

  defp walk(_encoding, _rest, _pairs), do: false

  # More than one fits, which is the normal case: Shift-JIS allows a trail byte
  # anywhere in 0x40..0xFC, so a file of 0xA1..0xFE pairs parses as all three.
  # Structure is exhausted, and what the bytes *are* has to decide.
  #
  # Shift-JIS keeps kana and most kanji in the rows 0x81..0x9F — あ is 0x82A0,
  # ア is 0x8341 — and those rows are not lead bytes in EUC-JP at all (0x8E and
  # 0x8F are its own two singles, so they do not count as evidence) and are the
  # rarely-reached end of GBK. A row from there is the strongest signal there is
  # without a frequency model.
  #
  # Between EUC-JP and GBK, both pairs of 0xA1..0xFE and indistinguishable by
  # shape: Japanese prose is mostly kana, which EUC-JP puts in the two rows 0xA4
  # (hiragana) and 0xA5 (katakana), while Chinese has no kana and spreads over
  # the hanzi rows.
  defp among(several, sample) do
    cond do
      :cp932 in several and shift_jis_rows?(sample) -> :cp932
      :euc_jp in several and :gbk in several -> if kana_heavy?(sample), do: :euc_jp, else: :gbk
      :euc_jp in several -> :euc_jp
      :gbk in several -> :gbk
      true -> hd(several)
    end
  end

  defp shift_jis_rows?(sample) do
    Enum.any?(:binary.bin_to_list(sample), &(&1 in 0x81..0x8D or &1 in 0x90..0x9F))
  end

  defp kana_heavy?(sample), do: kana_ratio(sample, 0, 0)

  defp kana_ratio(<<>>, kana, pairs), do: pairs > 0 and kana / pairs > 0.2

  defp kana_ratio(<<lead, _trail, rest::binary>>, kana, pairs) when lead in 0xA1..0xFE,
    do: kana_ratio(rest, kana + if(lead in [0xA4, 0xA5], do: 1, else: 0), pairs + 1)

  defp kana_ratio(<<_byte, rest::binary>>, kana, pairs), do: kana_ratio(rest, kana, pairs)

  # ── single-byte code pages ────────────────────────────────────────

  # A byte in 0x80..0x9F is a control character in Latin-1 and a printable one
  # in Windows-1252 (quotes, dashes, the euro), so text holding one is 1252.
  # Cyrillic is the other way about: a word of it is a run of high bytes, where
  # a French accent sits alone between ASCII letters.
  defp single_byte(sample) do
    cond do
      runs?(sample) -> :cp1251
      Enum.any?(:binary.bin_to_list(sample), &(&1 in 0x80..0x9F)) -> :cp1252
      true -> :latin1
    end
  end

  defp runs?(sample) do
    {runs, longest, current} =
      Enum.reduce(:binary.bin_to_list(sample), {0, 0, 0}, fn byte, {runs, longest, current} ->
        if byte >= 0xC0 do
          {runs, max(longest, current + 1), current + 1}
        else
          {runs + if(current >= 3, do: 1, else: 0), longest, 0}
        end
      end)

    runs + if(current >= 3, do: 1, else: 0) > 0 and longest >= 3
  end

  # ── decoding ──────────────────────────────────────────────────────

  defp utf16(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}, :utf8) do
      text when is_binary(text) -> text
      _ -> latin1(bytes)
    end
  end

  defp latin1(bytes) do
    case :unicode.characters_to_binary(bytes, :latin1, :utf8) do
      text when is_binary(text) -> text
      _ -> bytes
    end
  end

  # `//TRANSLIT` so one character iconv hasn't got cannot cost the whole file,
  # and the Latin-1 reading if there is no iconv to call.
  defp iconv(bytes, from) do
    path = Path.join(System.tmp_dir!(), "laev-enc-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)

    try do
      case System.cmd("iconv", ["-f", from, "-t", "UTF-8//TRANSLIT", path], stderr_to_stdout: true) do
        {text, 0} -> if String.valid?(text), do: text, else: latin1(bytes)
        _ -> latin1(bytes)
      end
    rescue
      _ -> latin1(bytes)
    after
      File.rm(path)
    end
  end
end
