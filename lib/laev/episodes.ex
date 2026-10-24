defmodule Laev.Episodes do
  @moduledoc """
  Which episode a release is numbered with, and whether what came back is it.

  Releases do not agree with TMDB about numbering, and anime is where it shows.
  MyAnimeList lists every cour as its own entry; TMDB sometimes merges them into
  one season — *You and I Are Polar Opposites* is two cours of twelve and
  thirteen, and one 25-episode season. Releases are then named either way, and a
  pack named "(13-25)" numbers its files 13..25 across the whole season rather
  than 1..13 within its own cour.

  So a release is asked for the number *it* uses: the TMDB number when it is
  named with a range that starts above one, and otherwise the number the caller
  asked for. And what the provider hands back is checked against what was
  wanted, because a file that plays is not the same thing as the right file.

  A context here is a map with `:episode`, and optionally `:tmdb_episode` (the
  same episode as TMDB numbers it), `:season`, and `:anime`.
  """

  @doc """
  The episode number to ask a release for.

  A pack named with a range that does not start at one numbers its files across
  the whole TMDB season, so it is asked for the TMDB number — episode 3 of the
  second cour is file 15. Everything else is asked for what the caller wanted.
  """
  def numbered_as(release_name, ctx) when is_binary(release_name) do
    tmdb = ctx[:tmdb_episode]

    with true <- is_integer(tmdb),
         [_, from, to] <- Regex.run(~r/(\d{1,4})\s*[-~–]\s*(\d{1,4})/, release_name),
         {from, to} = {String.to_integer(from), String.to_integer(to)},
         true <- from > 1 and from <= to and tmdb in from..to do
      tmdb
    else
      _ -> ctx[:episode]
    end
  end

  def numbered_as(_release_name, ctx), do: ctx[:episode]

  @doc """
  Group sources by the number they should be asked for, so each is probed with
  its own numbering: `[{episode, sources}]`.

  Takes whatever shape the prober already uses — a source map, or a
  `{source, index}` pair.
  """
  def group_by_numbering(sources, ctx) do
    sources
    |> Enum.group_by(fn item -> numbered_as(name_of(item), ctx) end)
    |> Enum.to_list()
  end

  defp name_of(%{name: name}), do: name
  defp name_of({%{name: name}, _index}), do: name
  defp name_of(_item), do: ""

  @doc """
  Confirm that a resolved stream really is the episode that was asked for.

  Passes `{:ok, stream}` through when it is, and turns it into an error when it
  isn't. Two ways it isn't: the file names a different episode outright, or it
  came out of a pack and names nothing like the episode wanted — which is what
  the largest-file fallback used to hand over.
  """
  def confirm({:ok, stream} = ok, source, ctx) do
    name = stream[:filename]

    cond do
      not is_binary(name) ->
        ok

      wrong_numbering?(name, ctx) ->
        {:error, :another_episode}

      pack?(source_name(source)) and not names_episode?(name, source_name(source), ctx) ->
        {:error, :no_file_for_episode}

      true ->
        ok
    end
  end

  def confirm(other, _source, _ctx), do: other

  defp source_name(%{name: name}) when is_binary(name), do: name
  defp source_name(name) when is_binary(name), do: name
  defp source_name(_source), do: ""

  @doc """
  Does this file name an episode other than the one wanted?

  A file saying "S02E01" is that episode whatever was asked for: a single-file
  release of another episode plays perfectly well and is not what anyone
  clicked. For anime, a later cour is often season 2 of the release's own
  numbering while TMDB has it as season 1, so the season is only checked for
  being the first or not.
  """
  def wrong_numbering?(file, ctx) when is_binary(file) do
    wanted = Enum.filter([ctx[:episode], ctx[:tmdb_episode]], &is_integer/1)

    case Regex.run(~r/S(\d{1,2})\s*E(\d{1,4})/i, Path.basename(file)) do
      [_, season, episode] ->
        season = String.to_integer(season)
        episode = String.to_integer(episode)

        season_ok =
          cond do
            not ctx[:anime] -> season == ctx[:season]
            ctx[:tmdb_episode] == ctx[:episode] -> season == 1
            true -> season != 1
          end

        episode not in wanted or not season_ok

      _ ->
        # Fansub style: "Show - 13v2 (1080p)".
        case ctx[:anime] && Regex.run(~r/ - (\d{1,4})(?:v\d)?(?=[\s.\[(]|$)/, Path.basename(file)) do
          [_, episode] -> String.to_integer(episode) not in wanted
          _ -> false
        end
    end
  end

  def wrong_numbering?(_file, _ctx), do: false

  @doc "Is this release a pack of several episodes rather than one?"
  def pack?(name) when is_binary(name),
    do: Regex.match?(~r/\bbatch|complete|\d+\s*[-~–]\s*\d+|\bS\d+\b(?!E)/i, name)

  def pack?(_name), do: false

  @doc """
  Does this file, out of this release, name the episode wanted — asked with the
  number that release uses.
  """
  def names_episode?(file, release_name, ctx) do
    episode = numbered_as(release_name, ctx)
    season = if ctx[:anime], do: nil, else: ctx[:season]

    is_integer(episode) and Laev.FilePick.names_episode?(file, season, episode)
  end
end
