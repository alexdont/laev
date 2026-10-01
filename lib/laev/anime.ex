defmodule Laev.Anime do
  @moduledoc """
  What laev knows about an anime, as MyAnimeList counts it.

  Anime is tracked on its own terms here, not folded into TMDB's. MAL keeps a
  *season* as its own entry — "Lupin III: Part II" is one anime, with 155
  episodes and a length of its own — and that is the unit laev marks, counts and
  times anime in: a mark is `mal-1425-e12`, never a season of a TMDB show that
  happens to contain it.

  This is the small amount of detail those marks need to mean anything: the
  title to show, how many episodes there are, and how long one runs. It comes
  from the same list request the import already makes, so a full import leaves
  every anime on the list described, and nothing else ever has to ask. An anime
  laev plays that the list didn't cover is fetched once and kept.
  """

  @cache "anime.json"

  @doc "Remember a map of `mal_id => %{title:, episodes:, seconds:, status:, score:}`."
  def put_many(entries) when is_map(entries) do
    wire = Map.new(entries, fn {mal_id, fields} -> {to_string(mal_id), stringify(fields)} end)
    if wire != %{}, do: write(Map.merge(read(), wire))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Everything known, as `%{mal_id => fields}` with atom keys."
  def all do
    Map.new(read(), fn {id, fields} -> {String.to_integer(id), atomize(fields)} end)
  rescue
    _ -> %{}
  end

  @doc "What's known about one anime, or nil."
  def get(mal_id) when is_integer(mal_id) do
    case Map.get(read(), Integer.to_string(mal_id)) do
      fields when is_map(fields) -> atomize(fields)
      _ -> nil
    end
  end

  def get(_mal_id), do: nil

  @doc "The anime's title, or nil — never a fetch."
  def title(mal_id), do: with(%{title: title} <- get(mal_id), do: title, else: (_ -> nil))

  @doc """
  How many episodes the anime has, or nil.

  Read from the list, so it answers offline — which is what lets the home screen
  know a finished anime has no next episode without asking anyone.
  """
  def episodes(mal_id) do
    case get(mal_id) do
      %{episodes: count} when is_integer(count) and count > 0 -> count
      _ -> nil
    end
  end

  @doc """
  Make sure this anime is described, asking MAL once if it isn't.

  Called where a pause is already expected — after a play, during an import —
  never from a list.
  """
  def learn(mal_id) when is_integer(mal_id) do
    with nil <- get(mal_id),
         %{} = fields <- Laev.MAL.anime(mal_id) do
      put_many(%{mal_id => fields})
      fields
    else
      %{} = known -> known
      _ -> nil
    end
  end

  def learn(_mal_id), do: nil

  # ── the file ──────────────────────────────────────────────────────

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp write(map), do: File.write(path(), Jason.encode!(map))

  defp stringify(fields) do
    for {key, value} <- fields, into: %{}, do: {to_string(key), value}
  end

  defp atomize(fields) do
    %{
      title: fields["title"],
      episodes: fields["episodes"],
      seconds: fields["seconds"],
      status: fields["status"],
      score: fields["score"]
    }
  end

  defp path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    File.mkdir_p!(dir)
    Path.join(dir, @cache)
  end
end
