defmodule Laev.Tracks do
  @moduledoc """
  Audio / subtitle languages of a resolved stream.

  Release names only hint at audio ("Rus-Eng", "MULTi") and say nothing
  about subtitles, so the picker used to guess. Real-Debrid's
  `/streaming/mediaInfos` reads the actual container server-side and lists
  every track with an ISO 639-2 code; this module folds that answer into
  `%{audio: ["ru", "en"], subs: ["ru"]}` — the two-letter codes the rest of
  laev already speaks (`Config.lang/0`, Torrentio flags) — and renders it
  for the source row.
  """

  # ISO 639-2 (both B and T where they differ) → 639-1. Only languages that
  # actually show up on the indexers laev queries; anything else is passed
  # through as RD sent it rather than hidden.
  @iso %{
    "eng" => "en", "rus" => "ru", "ukr" => "uk", "jpn" => "ja", "kor" => "ko",
    "fre" => "fr", "fra" => "fr", "ger" => "de", "deu" => "de", "spa" => "es",
    "ita" => "it", "por" => "pt", "pol" => "pl", "chi" => "zh", "zho" => "zh",
    "dut" => "nl", "nld" => "nl", "swe" => "sv", "nor" => "no", "dan" => "da",
    "fin" => "fi", "tur" => "tr", "ara" => "ar", "heb" => "he", "hin" => "hi",
    "tha" => "th", "vie" => "vi", "cze" => "cs", "ces" => "cs", "hun" => "hu",
    "rum" => "ro", "ron" => "ro", "bul" => "bg", "gre" => "el", "ell" => "el",
    "est" => "et", "lav" => "lv", "lit" => "lt", "srp" => "sr", "hrv" => "hr",
    "slk" => "sk", "slo" => "sk", "slv" => "sl", "ind" => "id", "may" => "ms",
    "msa" => "ms", "kaz" => "kk", "bel" => "be", "cat" => "ca", "tgl" => "tl",
    "uzb" => "uz", "aze" => "az", "kat" => "ka", "geo" => "ka", "hye" => "hy",
    "arm" => "hy", "tgk" => "tg", "kir" => "ky"
  }

  # "Undetermined" and friends carry no information — a row saying 💬und
  # would only raise questions.
  @unknown ~w(und mis mul zxx)

  @doc """
  `%{audio: [..], subs: [..]}` from a mediaInfos body: two-letter codes in
  container order, deduped, undetermined tracks dropped. Never fails —
  a body without `details` yields empty lists.
  """
  def from_media_info(%{"details" => details}) when is_map(details) do
    %{audio: langs(details["audio"]), subs: langs(details["subtitles"])}
  end

  def from_media_info(_body), do: %{audio: [], subs: []}

  # RD keys tracks "eng1"/"rus2" — alphabetical, not container order. The
  # "stream" field ("0:3") is the real position; sort by it so the first
  # audio listed is the one mpv would pick by default.
  defp langs(streams) when is_map(streams) do
    streams
    |> Map.values()
    |> Enum.sort_by(&stream_index/1)
    |> Enum.map(&code/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp langs(_), do: []

  defp stream_index(%{"stream" => stream}) when is_binary(stream) do
    case stream |> String.split(":") |> List.last() |> Integer.parse() do
      {n, _} -> n
      :error -> 0
    end
  end

  defp stream_index(_), do: 0

  defp code(%{"lang_iso" => iso}) when is_binary(iso) do
    iso = String.downcase(iso)

    cond do
      iso in @unknown -> nil
      true -> Map.get(@iso, iso, iso)
    end
  end

  defp code(_), do: nil

  @doc ~S"""
  Row suffix like `🔊ru·en 💬ru`; sections with nothing known are left out,
  so a stream with no track info renders as "".
  """
  def label(%{audio: audio, subs: subs}) do
    [{"🔊", audio}, {"💬", subs}]
    |> Enum.reject(fn {_icon, codes} -> codes == [] end)
    |> Enum.map_join(" ", fn {icon, codes} -> icon <> Enum.join(codes, "·") end)
  end

  def label(_), do: ""
end
