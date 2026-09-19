defmodule Laev.TracksTest do
  use ExUnit.Case, async: true

  alias Laev.Tracks

  # Shape of GET /streaming/mediaInfos/{id} — keys like "eng1"/"rus2" are
  # RD's own, the "stream" field carries the container order.
  @body %{
    "details" => %{
      "video" => %{"und1" => %{"stream" => "0:0", "codec" => "hevc"}},
      "audio" => %{
        "eng2" => %{"stream" => "0:3", "lang" => "English", "lang_iso" => "eng", "codec" => "eac3"},
        "rus1" => %{"stream" => "0:1", "lang" => "Russian", "lang_iso" => "rus", "codec" => "ac3"},
        "rus2" => %{"stream" => "0:2", "lang" => "Russian", "lang_iso" => "rus", "codec" => "aac"}
      },
      "subtitles" => %{
        "und1" => %{"stream" => "0:4", "lang" => "Unknown", "lang_iso" => "und", "type" => "SRT"},
        "rus1" => %{"stream" => "0:5", "lang" => "Russian", "lang_iso" => "rus", "type" => "SRT"},
        "ukr1" => %{"stream" => "0:6", "lang" => "Ukrainian", "lang_iso" => "ukr", "type" => "ASS"}
      }
    }
  }

  test "folds ISO 639-2 to two-letter codes, keeps container order, dedupes" do
    assert Tracks.from_media_info(@body) == %{audio: ["ru", "en"], subs: ["ru", "uk"]}
  end

  test "drops undetermined languages, keeps unknown codes as-is" do
    body = %{
      "details" => %{
        "audio" => %{"und1" => %{"stream" => "0:1", "lang_iso" => "und"}},
        "subtitles" => %{"xx1" => %{"stream" => "0:2", "lang_iso" => "xyz"}}
      }
    }

    assert Tracks.from_media_info(body) == %{audio: [], subs: ["xyz"]}
  end

  test "tolerates a body without details or with missing sections" do
    assert Tracks.from_media_info(%{}) == %{audio: [], subs: []}
    assert Tracks.from_media_info(%{"details" => %{"audio" => nil}}) == %{audio: [], subs: []}
  end

  test "label shows audio and subtitles, omitting empty sections" do
    assert Tracks.label(%{audio: ["ru", "en"], subs: ["ru"]}) == "🔊ru·en 💬ru"
    assert Tracks.label(%{audio: ["en"], subs: []}) == "🔊en"
    assert Tracks.label(%{audio: [], subs: ["en"]}) == "💬en"
    assert Tracks.label(%{audio: [], subs: []}) == ""
    assert Tracks.label(nil) == ""
  end
end
