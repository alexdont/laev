defmodule Laev.FilePick do
  @moduledoc """
  Choosing the right video file inside a torrent — shared by every debrid
  provider. Files come in as maps with `"path"` and `"bytes"` (plus whatever
  provider-specific keys the caller wants back, e.g. `"id"`).
  """

  @video_exts ~w(.mkv .mp4 .avi .m4v .ts .webm .mov .ogv)

  @doc """
  Pick the file to play: the only video, the requested episode from a
  batch/season pack, or the largest video. `{:ok, file}` or
  `{:error, :no_video_files}`.
  """
  def choose(files, episode, season) when is_list(files) do
    videos = Enum.filter(files, fn f -> Path.extname(String.downcase(f["path"] || "")) in @video_exts end)

    case videos do
      [] ->
        {:error, :no_video_files}

      [only] ->
        {:ok, only}

      many ->
        # Batch/season pack: pick the file for the requested episode; otherwise
        # (single-episode releases, or no match) fall back to the largest file.
        chosen =
          (episode && pick_episode_file(many, episode, season)) ||
            Enum.max_by(many, &(&1["bytes"] || 0))

        {:ok, chosen}
    end
  end

  def choose(_files, _episode, _season), do: {:error, :no_video_files}

  # Choose the file for a given episode. When the season is known (live-action
  # TV), require an exact SxxExx match first so a multi-season pack can't grab
  # the same episode number from the wrong season; fall back to a looser
  # episode-only match (anime absolute numbering, single-season packs).
  @doc """
  Does this file actually hold the episode asked for?

  `choose/3` falls back to the largest file when nothing matches, which is right
  when a release is one episode named anything — and wrong as an answer to "is
  episode 13 in this pack?". Anything reusing a pack has to ask this instead, or
  it will happily play episode 1 again and call it 13.
  """
  def names_episode?(path, season, episode) when is_binary(path) and is_integer(episode) do
    cond do
      is_integer(season) and sxxexx_file?(path, season, episode) ->
        true

      # A file that names some other season's episode 13 is not this season's
      # episode 13 — the loose matcher would say yes, because "s02e13" contains
      # the episode number. Multi-season packs are exactly where reuse would go
      # wrong, and quietly.
      is_integer(season) and Regex.match?(~r/s\d{1,2}e\d{1,3}/i, Path.basename(path)) ->
        false

      true ->
        episode_file?(path, episode)
    end
  end

  def names_episode?(_path, _season, _episode), do: false

  defp pick_episode_file(files, episode, season) do
    (season && Enum.find(files, &sxxexx_file?(&1["path"], season, episode))) ||
      Enum.find(files, &episode_file?(&1["path"], episode))
  end

  # Exact SxxExx (season + episode), e.g. "Lupin.S01E01." — the (?![0-9]) stops
  # E1 from matching E11/E1x.
  defp sxxexx_file?(path, season, episode) do
    Regex.match?(~r/s0*#{season}e0*#{episode}(?![0-9])/i, Path.basename(path))
  end

  # Does this filename correspond to the given episode number? Tokenize and look
  # for the number as a standalone token (or E24 / S01E24), so "GTO - 24" matches
  # but "GTO 2024"/"1080p" don't.
  defp episode_file?(path, episode) do
    ep = Integer.to_string(episode)
    padded = String.pad_leading(ep, 2, "0")

    path
    |> Path.basename()
    |> String.downcase()
    |> then(&Regex.split(~r/[\s_\-.\[\]()]+/, &1))
    |> Enum.any?(fn tok ->
      tok in [ep, padded, "e#{ep}", "e#{padded}"] or Regex.match?(~r/^s\d+e0*#{episode}$/, tok)
    end)
  end
end
