defmodule Laev.Subtitles do
  @moduledoc """
  Convert subtitle files to WebVTT, which is the only format an HTML5
  `<video>` `<track>` accepts. Handles SubRip (.srt) and Advanced SubStation
  Alpha (.ass, common for anime), dispatching on the file name.
  """

  @extensions ~w(.srt .ass .ssa .vtt .sub)

  @doc "Known subtitle file extensions."
  def extensions, do: @extensions

  @doc "True when the filename ends in a known subtitle extension."
  def subtitle_filename?(name), do: Path.extname(String.downcase(name)) in @extensions

  @doc "Convert by file extension; falls back to SRT handling."
  def to_vtt(filename, content) do
    text = to_utf8(content)
    name = String.downcase(filename || "")

    cond do
      String.starts_with?(text, "WEBVTT") -> text
      String.ends_with?(name, [".ass", ".ssa"]) -> ass_to_vtt(text)
      true -> srt_to_vtt(text)
    end
  end

  @doc """
  A subtitle file's text, whatever it was encoded in.

  Subtitle files in the wild are UTF-8, UTF-8 with a byte-order mark, UTF-16,
  or Latin-1 — which is most French and other Western European releases, and
  which arrives as mojibake or nothing at all if read as UTF-8. Anything that
  is not valid UTF-8 is read as Latin-1: right for those, wrong for Shift-JIS
  Japanese, which would need a real encoding detector to tell apart.
  """
  def to_utf8(<<0xFF, 0xFE, rest::binary>>), do: utf16(rest, :little)
  def to_utf8(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest, :big)
  def to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: to_utf8(rest)

  def to_utf8(content) when is_binary(content) do
    if String.valid?(content),
      do: content,
      else: :unicode.characters_to_binary(content, :latin1, :utf8)
  end

  def to_utf8(content), do: content

  defp utf16(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}, :utf8) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  @doc "SubRip → WebVTT: add the header and switch the comma decimal to a dot."
  def srt_to_vtt(srt) do
    body =
      srt
      |> strip_bom()
      |> String.replace("\r\n", "\n")
      |> String.replace(~r/(\d{2}:\d{2}:\d{2}),(\d{3})/, "\\1.\\2")

    "WEBVTT\n\n" <> body
  end

  @doc """
  ASS → WebVTT: keep only the dialogue events, drop styling/override tags.
  Not a full ASS renderer, but yields readable timed text the browser shows.
  """
  def ass_to_vtt(ass) do
    cues =
      ass
      |> strip_bom()
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "Dialogue:"))
      |> Enum.map(&parse_dialogue/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {start, stop, text} -> "#{start} --> #{stop}\n#{text}" end)

    "WEBVTT\n\n" <> Enum.join(cues, "\n\n")
  end

  defp parse_dialogue("Dialogue:" <> rest) do
    # Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    case String.split(rest, ",", parts: 10) do
      [_layer, start, stop, _style, _name, _ml, _mr, _mv, _effect, text] ->
        cleaned = clean_ass_text(text)
        if cleaned == "", do: nil, else: {ass_time(start), ass_time(stop), cleaned}

      _ ->
        nil
    end
  end

  # ASS time is H:MM:SS.cc (centiseconds); VTT wants HH:MM:SS.mmm.
  defp ass_time(time) do
    case Regex.run(~r/(\d+):(\d{2}):(\d{2})\.(\d{2})/, String.trim(time)) do
      [_, h, m, s, cs] -> "#{String.pad_leading(h, 2, "0")}:#{m}:#{s}.#{cs}0"
      _ -> "00:00:00.000"
    end
  end

  defp clean_ass_text(text) do
    text
    |> String.replace(~r/\{[^}]*\}/, "")
    |> String.replace(~r/\\[Nnh]/, "\n")
    |> String.trim()
  end

  defp strip_bom(text), do: String.replace_prefix(text, "﻿", "")
end
