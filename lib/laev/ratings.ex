defmodule Laev.Ratings do
  @moduledoc """
  Your TMDB ratings, read back as "I have watched this".

  A rating is the one unambiguous record of having seen something — nobody
  scores a film they haven't watched — and a TMDB account can hold years of them,
  imported from IMDb. Reading them in is what makes the rest of laev tell the
  truth about a library it never played: titles grey out in search and Featured,
  and the stats stop pretending a decade of watching began when laev was
  installed.

  Marks only. No resume points, no history entries, no sources: laev didn't play
  these, and the stats keep them in the off-laev bucket where an assumed runtime
  belongs.
  """

  alias Laev.{Position, Sync, Tmdb}

  @doc """
  Mark everything you have rated on TMDB as watched.

  Returns `%{marked:, already:, partial:, failed:}`. Idempotent — a second run
  marks nothing, because everything is already marked.

  `report` is called with progress lines so a long import can speak for itself.
  """
  def import_from_tmdb(report \\ fn _line -> :ok end) do
    if Tmdb.account?() do
      report.("reading your ratings from TMDB…")

      films = Tmdb.rated("movies", &report.("  #{&1} films…"))
      shows = Tmdb.rated("tv", &report.("  #{&1} shows…"))
      episodes = Tmdb.rated("tv/episodes", &report.("  #{&1} episodes…"))

      # The names ride along in the same response, so the stats page has something
      # readable for a title it has never played — otherwise a thousand imported
      # rows read as "tv #4607", which says nothing about what you watched.
      remember_names(films, shows)

      counts =
        [
          Enum.map(films, &ctx_for_movie/1),
          Enum.map(shows, &ctx_for_show/1),
          Enum.map(episodes, &ctx_for_episode/1)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(%{marked: 0, already: 0, partial: 0, failed: 0}, &mark/2)

      if counts.marked > 0, do: Sync.live_push()
      counts
    else
      {:error, :no_session}
    end
  end

  @doc """
  What to do with one rated title, given what laev already knows about it.

  The only interesting case is the middle one: a part-watched position is
  somebody's place in something, and an import must not stamp over it with
  "finished" on the strength of a rating that might predate the rewatch.
  """
  def decide(:none), do: :mark
  def decide(:watched), do: :already
  def decide({:partial, _seconds}), do: :partial

  defp mark(ctx, counts) do
    case decide(Position.mark_state(ctx)) do
      :mark ->
        Position.set_watched(ctx, true)
        if Position.mark_state(ctx) == :watched,
          do: %{counts | marked: counts.marked + 1},
          else: %{counts | failed: counts.failed + 1}

      :already ->
        %{counts | already: counts.already + 1}

      :partial ->
        %{counts | partial: counts.partial + 1}
    end
  end

  defp remember_names(films, shows) do
    names =
      Map.merge(
        for(%{"id" => id, "title" => title} <- films, into: %{}, do: {{"movie", id}, title}),
        for(%{"id" => id, "name" => name} <- shows, into: %{}, do: {{"tv", id}, name})
      )

    Laev.Titles.put(names)
  end

  defp ctx_for_movie(%{"id" => id}) when is_integer(id),
    do: %{type: "movie", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_movie(_rated), do: nil

  # A rated series is a watched series, at title level — the same mark ctrl-w
  # writes, so the ✓ and the greying agree with it.
  defp ctx_for_show(%{"id" => id}) when is_integer(id),
    do: %{type: "tv", tmdb_id: id, season: nil, episode: nil}

  defp ctx_for_show(_rated), do: nil

  defp ctx_for_episode(%{"show_id" => show, "season_number" => season, "episode_number" => episode})
       when is_integer(show) and is_integer(season) and is_integer(episode),
       do: %{type: "tv", tmdb_id: show, season: season, episode: episode}

  defp ctx_for_episode(_rated), do: nil
end
