defmodule Laev.Jimaku do
  @moduledoc """
  Jimaku (jimaku.cc) client — a database of Japanese anime subtitles, indexed
  per anime and per episode. Searching/listing needs the API key; the actual
  subtitle files download from public URLs (no key).
  """

  @base "https://jimaku.cc/api"

  def configured?, do: key() not in [nil, ""]

  @doc "Search anime entries by name. Returns `{:ok, [entry]}` (raw maps)."
  def search(query), do: get("/entries/search", query: query)

  @doc "List subtitle files for an entry, optionally filtered to one episode."
  def files(entry_id, episode) do
    params = if episode, do: [episode: episode], else: []
    get("/entries/#{entry_id}/files", params)
  end

  @doc """
  Find the best subtitle file for a title + episode in the given language
  (`:japanese` or `:english`), preferring .srt over .ass. Jimaku hosts both for
  many anime (JP official rips + EN fansubs). Returns `{:ok, %{name, url}}`.
  """
  def subtitle_file(query, episode, lang) do
    with {:ok, [entry | _]} <- search(query),
         {:ok, files} <- files(entry["id"], episode) do
      pick(Enum.sort_by(files, &format_rank/1), lang)
    else
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Japanese: a Japanese name (`.ja` / kana / kanji) reliably means JP content.
  defp pick(files, :japanese) do
    case Enum.find(files, &japanese_named?/1) do
      nil -> {:error, :no_file}
      file -> {:ok, to_result(file)}
    end
  end

  # English is unreliable by filename — romaji-named files are often Japanese
  # "raws" (e.g. [NanakoRaws]). Verify by actually fetching content and checking
  # the Japanese-character ratio; return the first genuinely non-Japanese file,
  # carrying the fetched body so the caller doesn't download it again.
  defp pick(files, :english) do
    files
    |> Enum.reject(&japanese_named?/1)
    |> Enum.filter(&subtitle_named?/1)
    |> Enum.find_value({:error, :no_file}, fn file ->
      case classify_by_content(file["url"]) do
        {:english, body} -> {:ok, to_result(file, body)}
        _ -> nil
      end
    end)
  end

  defp to_result(file, body \\ nil), do: %{name: file["name"], url: file["url"], body: body}

  defp japanese_named?(%{"name" => name}) do
    String.contains?(name, ".ja") or String.match?(name, ~r/[\x{3040}-\x{30ff}\x{4e00}-\x{9fff}]/u)
  end

  defp subtitle_named?(%{"name" => name}), do: Laev.Subtitles.subtitle_filename?(name)

  # Download the file and classify by its *dialogue* text (ignoring the .ass
  # header, whose field names are Latin and would masquerade as English).
  # Returns `{classification, body}` so the winning file's content can be
  # reused instead of downloaded a second time.
  defp classify_by_content(url) do
    case Req.get(Req.new(url: url, receive_timeout: 15_000, retry: :transient, max_retries: 1)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {classify(dialogue_text(body)), body}
      _ -> {:unknown, nil}
    end
  end

  defp dialogue_text(body) do
    if String.contains?(body, "Dialogue:") do
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "Dialogue:"))
      |> Enum.map_join(" ", fn line ->
        case String.split(line, ",", parts: 10) do
          [_, _, _, _, _, _, _, _, _, text] -> String.replace(text, ~r/\{[^}]*\}/, "")
          _ -> ""
        end
      end)
    else
      body
    end
  end

  # Japanese has kana; Chinese has CJK ideographs but no kana; English is Latin.
  defp classify(text) do
    chars = text |> String.slice(0, 4000) |> String.graphemes()
    total = max(length(chars), 1)
    kana = ratio(chars, total, ~r/[\x{3040}-\x{30ff}]/u)
    cjk = ratio(chars, total, ~r/[\x{4e00}-\x{9fff}]/u)
    latin = ratio(chars, total, ~r/[A-Za-z]/)

    cond do
      kana >= 0.03 -> :japanese
      cjk >= 0.03 -> :chinese
      latin >= 0.15 -> :english
      true -> :unknown
    end
  end

  defp ratio(chars, total, regex), do: Enum.count(chars, &String.match?(&1, regex)) / total

  # Prefer .srt (cleanest conversion), then .ass, then anything else.
  defp format_rank(%{"name" => name}) do
    name = String.downcase(name)

    cond do
      String.ends_with?(name, ".srt") -> 0
      String.ends_with?(name, ".ass") -> 1
      true -> 2
    end
  end

  defp get(path, params) do
    req = Req.new(base_url: @base, headers: [{"authorization", key()}], retry: :transient, max_retries: 2, receive_timeout: 15_000)

    case Req.get(req, url: path, params: params) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:jimaku, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp key, do: Laev.Scope.get(:jimaku_api_key)

  @doc """
  The Japanese subtitle files Jimaku has for an episode, most likely first.

  Jimaku holds several per episode — the broadcast, Netflix's and Amazon's cuts,
  fansub groups' — and they are not all timed alike, so the first one found is
  often a streaming cut running half a minute off a rip. `subtitle_file/3` takes
  that first one; this offers the plausible ones in order, so a player can put
  them in a menu and the viewer can switch when the timing is wrong.

  `release_name` is what is being played: a file from the same group comes
  first, since it was timed against that very rip.

  `{:ok, [%{name:, url:, group:}]}` or `{:error, reason}`.
  """
  def candidates(query, episode, release_name \\ nil, limit \\ 5) do
    with {:ok, [_ | _] = entries} <- search(query),
         entry = best_entry(entries, query),
         {:ok, files} <- files(entry["id"], episode) do
      ranked =
        files
        |> Enum.filter(&japanese_named?/1)
        |> Enum.sort_by(&{rank(&1["name"], release_name), &1["name"]})
        |> Enum.uniq_by(&base_name/1)
        |> Enum.take(limit)
        |> Enum.map(&%{name: &1["name"], url: &1["url"], group: group_of(&1["name"])})

      if ranked == [], do: {:error, :no_file}, else: {:ok, ranked}
    else
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Jimaku lists a show's seasons as separate entries and puts the first season
  # first, whichever was searched for — so an exact name match wins.
  defp best_entry(entries, query) do
    wanted = String.downcase(query || "")
    Enum.find(entries, &(String.downcase(&1["name"] || "") == wanted)) || hd(entries)
  end

  defp base_name(%{"name" => name}),
    do: name |> Path.rootname() |> String.replace(~r/\.(jpn|ja)$/i, "")

  defp base_name(_file), do: ""

  # The release's own group first — its timing was made against that rip; then
  # the broadcast and the big fansub groups, whose timings follow the rips;
  # streaming cuts and caption tracks last. SubRip before ASS, being simpler to
  # render and less likely to carry styling a browser ignores.
  defp rank(name, release_name) do
    name = String.downcase(name || "")
    group = group_of(release_name)

    base =
      cond do
        is_binary(group) and group != "" and String.contains?(name, group) -> 0
        String.contains?(name, ["nanako", "tbs", "subsplease", "erai", "judas"]) -> 1
        String.contains?(name, ["netflix", "amazon", "[cc]", "[sdh]", "crunchyroll"]) -> 3
        true -> 2
      end

    base * 2 + if String.ends_with?(name, ".srt"), do: 0, else: 1
  end

  defp group_of(name) when is_binary(name) do
    case Regex.run(~r/^\[([^\]]+)\]/, name) do
      [_, group] -> String.downcase(group)
      _ -> nil
    end
  end

  defp group_of(_name), do: nil
end
