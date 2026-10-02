defmodule Laev.Cards do
  @moduledoc """
  The dozen TMDB fields a list row is made of, kept on disk.

  A row needs a title, a year, a poster, an overview, a score, and — for a show —
  how long each season is and whether it has ended. None of that changes hour to
  hour, and the Watchlist was asking TMDB for all of it every time it opened:
  seventy-eight requests to draw a page whose answer was the same as last time.
  Now it asks for what it has never seen and nothing else.

  Trimmed on the way in, because the full response is ten times the size and the
  rest of it is credits, networks and image lists no row has ever read.

  Refreshed in the background — a day old for a show, which gains seasons, a week
  for a film, which doesn't — and never in front of the screen. A card that can't
  be refreshed stays: a slightly old year is a better row than no row.
  """

  @cache "cards.json"
  # A film is finished being made; a show gains seasons, and being told a week
  # late that one started is how a page ends up saying you are caught up on
  # something that aired on Tuesday. Neither wait costs anything on screen —
  # refreshing happens behind the list either way.
  @stale_tv 24 * 3600
  @stale_movie 7 * 24 * 3600

  # Exactly what the row builders read, and nothing else.
  @fields ~w(id name title first_air_date release_date poster_path overview vote_average
             popularity status number_of_episodes number_of_seasons)
  @season_fields ~w(season_number episode_count air_date)

  @doc "Cards for these `{type, id}` keys that are already known."
  def get_many(keys) do
    stored = read()

    for key <- keys, card = stored[disk_key(key)], into: %{} do
      {key, strip_meta(card)}
    end
  end

  @doc "One card, or nil."
  def get(type, id), do: get_many([{type, id}])[{type, id}]

  @doc "Remember a map of `{type, id} => TMDB details`, trimmed, in one write."
  def put_many(details) when is_map(details) do
    now = System.os_time(:second)

    fresh =
      for {key, body} <- details, is_map(body), into: %{} do
        {disk_key(key), body |> trim() |> Map.put("laev_at", now)}
      end

    if fresh != %{}, do: write(Map.merge(read(), fresh))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Which of these keys are old enough to be worth asking about again."
  def stale(keys) do
    stored = read()
    now = System.os_time(:second)

    Enum.filter(keys, fn {type, _id} = key ->
      case stored[disk_key(key)] do
        %{"laev_at" => at} when is_integer(at) -> at < now - max_age(type)
        _ -> false
      end
    end)
  end

  defp max_age("tv"), do: @stale_tv
  defp max_age(_type), do: @stale_movie

  # ── the file ──────────────────────────────────────────────────────

  defp trim(body) do
    body
    |> Map.take(@fields)
    |> Map.put("seasons", Enum.map(body["seasons"] || [], &Map.take(&1, @season_fields)))
  end

  defp strip_meta(card), do: Map.delete(card, "laev_at")

  defp disk_key({type, id}), do: "#{type}-#{id}"

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp write(map), do: File.write(path(), Jason.encode!(map))

  defp path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    File.mkdir_p!(dir)
    Path.join(dir, @cache)
  end
end
