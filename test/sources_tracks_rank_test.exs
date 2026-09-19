defmodule Laev.SourcesTracksRankTest do
  # Not async: ranking reads the language preference from the app env.
  use ExUnit.Case

  alias Laev.Sources

  # Minimal playable pairs — same tier and size, so only lang_score differs.
  defp pair(name, attrs) do
    source =
      Map.merge(
        %{name: name, resolution: "1080p", source: "WEB", size: 1, seeders: 1, lang: nil},
        attrs
      )

    {source, %{url: "https://example/#{name}"}}
  end

  defp order(pairs), do: pairs |> Sources.rank_playable() |> Enum.map(fn {s, _} -> s.name end)

  setup do
    lang = Application.get_env(:laev_app, :lang)
    subs = Application.get_env(:laev_app, :subs_lang)

    on_exit(fn ->
      Application.put_env(:laev_app, :lang, lang)
      Application.put_env(:laev_app, :subs_lang, subs)
    end)

    :ok
  end

  test "English default: foreign audio with English subs stays neutral, without them sinks" do
    Application.put_env(:laev_app, :lang, "en")
    Application.put_env(:laev_app, :subs_lang, nil)

    untagged = pair("untagged", %{})
    anime = pair("ja+en-subs", %{langs: ["ja"], subs: ["en"]})
    dub_only = pair("ja-only", %{langs: ["ja"], subs: []})

    # Neutral means tied with untagged (stable sort keeps input order), and
    # never below the wrong-language row.
    assert order([dub_only, anime, untagged]) == ["ja+en-subs", "untagged", "ja-only"]
    assert order([dub_only, untagged, anime]) == ["untagged", "ja+en-subs", "ja-only"]
  end

  test "non-English preference: real audio ranks exact > multi > subs-only > wrong" do
    Application.put_env(:laev_app, :lang, "ru")
    Application.put_env(:laev_app, :subs_lang, "ru")

    exact = pair("ru", %{langs: ["ru"]})
    multi = pair("ru+en", %{langs: ["ru", "en"]})
    subs_only = pair("en+ru-subs", %{langs: ["en"], subs: ["ru"]})
    wrong = pair("en", %{langs: ["en"], subs: ["en"]})

    assert order([wrong, subs_only, multi, exact]) == ["ru", "ru+en", "en+ru-subs", "en"]
  end

  test "subtitles are ignored when LAEV_SUBS is off" do
    Application.put_env(:laev_app, :lang, "ru")
    Application.put_env(:laev_app, :subs_lang, "off")

    subs_only = pair("en+ru-subs", %{langs: ["en"], subs: ["ru"]})
    untagged = pair("untagged", %{})

    assert order([subs_only, untagged]) == ["untagged", "en+ru-subs"]
  end
end
