defmodule Laev.Tmdb do
  @moduledoc """
  Minimal TMDB v3 API client — search, movie/TV details, season episodes.

  Accepts either a v3 API key or a v4 read-access token (JWTs start with "eyJ").
  """

  @base "https://api.themoviedb.org/3"
  @image_base "https://image.tmdb.org/t/p"

  def configured?, do: key() not in [nil, ""]

  @doc """
  Search movies and TV shows. Returns `{:ok, results, more?}` where `more?`
  says whether further pages exist.
  """
  def search(query, page \\ 1) do
    with {:ok, %{"results" => results} = body} <- get("/search/multi", query: query, page: page) do
      {:ok,
       results
       |> Enum.filter(&(&1["media_type"] in ~w(movie tv)))
       |> Enum.map(&normalize/1), page < (body["total_pages"] || 1)}
    end
  end

  @doc """
  The movie or show behind an IMDb id, as a normalized title — TMDB's reverse
  lookup. `{:error, :not_found}` when TMDB has nothing filed under it.

  TMDB's answer here can be a ghost: an entity that `find` names but `/tv/{id}`
  then 404s on. Callers have to be able to cope with the title not resolving.
  """
  def find_imdb("tt" <> _ = imdb_id) do
    case get("/find/#{imdb_id}", external_source: "imdb_id") do
      {:ok, body} ->
        [{"movie_results", "movie"}, {"tv_results", "tv"}]
        |> Enum.find_value(fn {key, type} ->
          case body[key] do
            [first | _] -> {:ok, normalize(Map.put(first, "media_type", type))}
            _ -> nil
          end
        end)
        |> Kernel.||({:error, :not_found})

      error ->
        error
    end
  end

  def find_imdb(_id), do: {:error, :not_found}

  @doc """
  Trending movies or TV shows this week — `type` is `"movie"` or `"tv"`.
  Returns `{:ok, results, more?}` like `search/2`.
  """
  def trending(type, page \\ 1) when type in ~w(movie tv) do
    with {:ok, %{"results" => results} = body} <- get("/trending/#{type}/week", page: page) do
      {:ok, Enum.map(results, &normalize(Map.put(&1, "media_type", type))),
       page < (body["total_pages"] || 1)}
    end
  end

  @doc """
  Post-credit stinger flags for a movie, from TMDB's community keywords:
  `{during_credits?, after_credits?}`. `{false, false}` on any failure —
  absence of a tag means "probably none", not certainty.
  """
  def stingers(movie_id) do
    case get("/movie/#{movie_id}/keywords") do
      {:ok, %{"keywords" => keywords}} ->
        names = Enum.map(keywords, & &1["name"])
        {"duringcreditsstinger" in names, "aftercreditsstinger" in names}

      _ ->
        {false, false}
    end
  end

  @doc """
  Top currently-airing anime — Japanese-language animation TV with an episode
  in the recent air-date window, popularity-first. Returns
  `{:ok, results, more?}` like `trending/2`.
  """
  def discover_anime(page \\ 1) do
    # Top airing NOW, not popular of all time: constrain to shows with an
    # episode air date in the recent window (catches weekly long-runners
    # and freshly started seasonals alike), ranked by current popularity.
    # No vote floor — a vote floor structurally excludes new seasons.
    today = Date.utc_today()

    with {:ok, %{"results" => results} = body} <-
           get("/discover/tv",
             with_genres: 16,
             with_original_language: "ja",
             sort_by: "popularity.desc",
             "air_date.gte": Date.to_iso8601(Date.add(today, -28)),
             "air_date.lte": Date.to_iso8601(Date.add(today, 7)),
             page: page
           ) do
      {:ok, Enum.map(results, &normalize(Map.put(&1, "media_type", "tv"))),
       page < (body["total_pages"] || 1)}
    end
  end

  # Append external_ids so `imdb_id/1` works for both movies (top-level imdb_id)
  # and TV (external_ids.imdb_id) — used to query Torrentio for more sources.
  # alternative_titles rides along free: a film uploaded under its original or
  # a regional name is still the film, and the source filter needs to know
  # every name it legitimately answers to.
  def movie(id), do: get("/movie/#{id}", append_to_response: "external_ids,alternative_titles")
  def tv(id), do: get("/tv/#{id}", append_to_response: "external_ids,alternative_titles")
  def season(tv_id, season_number), do: get("/tv/#{tv_id}/season/#{season_number}")

  @doc """
  A TMDB collection — its own idea of a franchise, with every film in it. Right
  for most series (John Wick, Pirates of the Caribbean, Jurassic Park), which is
  why only the ones it gets wrong are curated by hand.
  """
  def collection(id), do: get("/collection/#{id}")
  def release_dates(movie_id), do: get("/movie/#{movie_id}/release_dates")

  # ── your account: ratings ─────────────────────────────────────────
  #
  # IMDb has no way to do this. Its official API is paid, enterprise and
  # read-only, and submitting a rating means driving a logged-in imdb.com
  # session through an internal GraphQL endpoint — fragile, and it would mean
  # holding someone's IMDb password. TMDB rates episodes individually, with the
  # key laev already has, so that is where ratings go.

  @doc """
  True when laev holds a TMDB session, i.e. ratings can be sent.
  """
  def account?, do: session_id() not in [nil, ""]

  @doc """
  Start a login: returns `{:ok, token, url}`. The user opens `url`, approves,
  and then `finish_login/1` turns the token into a lasting session.
  """
  def start_login do
    case get("/authentication/token/new") do
      {:ok, %{"request_token" => token}} ->
        {:ok, token, "https://www.themoviedb.org/authenticate/#{token}"}

      {:ok, body} ->
        {:error, body}

      error ->
        error
    end
  end

  @doc "Exchange an approved request token for a session id."
  def finish_login(token) do
    case post("/authentication/session/new", %{request_token: token}) do
      {:ok, %{"session_id" => session}} -> {:ok, session}
      {:ok, body} -> {:error, body}
      error -> error
    end
  end

  @doc "Who the stored session belongs to, or nil."
  def account_name do
    with true <- account?(),
         {:ok, %{"username" => name}} <- get("/account", session_id: session_id()) do
      name
    else
      _ -> nil
    end
  end

  @doc """
  Rate one episode, 0.5–10 in half steps — TMDB's own scale, which is what
  makes rating an episode rather than a whole series possible at all.
  """
  def rate_episode(tv_id, season, episode, value) do
    rate("/tv/#{tv_id}/season/#{season}/episode/#{episode}/rating", value)
  end

  @doc "Rate a film, 0.5–10 in half steps."
  def rate_movie(movie_id, value), do: rate("/movie/#{movie_id}/rating", value)

  @doc "Your rating for an episode, or nil when you haven't rated it."
  def episode_rating(tv_id, season, episode) do
    with true <- account?(),
         {:ok, %{"rated" => %{"value" => value}}} <-
           get("/tv/#{tv_id}/season/#{season}/episode/#{episode}/account_states", session_id: session_id()) do
      value
    else
      _ -> nil
    end
  end

  @doc "Rate a whole series, 0.5–10 in half steps."
  def rate_tv(tv_id, value), do: rate("/tv/#{tv_id}/rating", value)

  @doc "Your rating for a whole series, or nil."
  def tv_rating(tv_id) do
    with true <- account?(),
         {:ok, %{"rated" => %{"value" => value}}} <- get("/tv/#{tv_id}/account_states", session_id: session_id()) do
      value
    else
      _ -> nil
    end
  end

  @doc "Remove your rating for a whole series."
  def clear_tv_rating(tv_id), do: clear("/tv/#{tv_id}/rating")

  @doc """
  What you have given this show's episodes, as `{average, count}` — or nil when
  you haven't rated any.

  Asked of TMDB in bulk rather than episode by episode: it keeps a list of every
  episode you have rated, so one request covers a whole series instead of one
  per episode.
  """
  def episode_average(tv_id) do
    ratings =
      rated_episodes()
      |> Enum.filter(&(&1["show_id"] == tv_id))
      |> Enum.map(& &1["rating"])
      |> Enum.filter(&is_number/1)

    case ratings do
      [] -> nil
      values -> {Enum.sum(values) / length(values), length(values)}
    end
  end

  # Every episode you have rated, across pages. Capped: a list long enough to
  # need ten pages is long enough that the average will not move.
  defp rated_episodes(page \\ 1, acc \\ [])

  defp rated_episodes(page, acc) when page > 10, do: acc

  defp rated_episodes(page, acc) do
    with account when is_integer(account) <- account_id(),
         {:ok, %{"results" => results} = body} <-
           get("/account/#{account}/rated/tv/episodes", session_id: session_id(), page: page) do
      acc = acc ++ results

      if page < (body["total_pages"] || 1), do: rated_episodes(page + 1, acc), else: acc
    else
      _ -> acc
    end
  end

  defp account_id do
    with true <- account?(),
         {:ok, %{"id" => id}} <- get("/account", session_id: session_id()) do
      id
    else
      _ -> nil
    end
  end

  @doc "Your rating for a film, or nil when you haven't rated it."
  def movie_rating(movie_id) do
    with true <- account?(),
         {:ok, %{"rated" => %{"value" => value}}} <- get("/movie/#{movie_id}/account_states", session_id: session_id()) do
      value
    else
      _ -> nil
    end
  end

  @doc "Remove your rating for an episode."
  def clear_episode_rating(tv_id, season, episode),
    do: clear("/tv/#{tv_id}/season/#{season}/episode/#{episode}/rating")

  @doc "Remove your rating for a film."
  def clear_movie_rating(movie_id), do: clear("/movie/#{movie_id}/rating")

  defp clear(path) do
    with true <- account?(),
         {:ok, %{"success" => true}} <- request(:delete, path, [session_id: session_id()], []) do
      :ok
    else
      false -> {:error, :no_session}
      {:ok, body} -> {:error, body}
      error -> error
    end
  end

  defp rate(path, value) do
    with true <- account?(),
         rating when is_number(rating) <- round_half(value),
         {:ok, %{"success" => true}} <- post(path, %{value: rating}, session_id: session_id()) do
      {:ok, rating}
    else
      false -> {:error, :no_session}
      nil -> {:error, :out_of_range}
      {:ok, body} -> {:error, body}
      error -> error
    end
  end

  @doc """
  A score on TMDB's scale: half steps, 0.5 to 10. nil for anything outside it,
  so a typo doesn't become a rating of 1.
  """
  def round_half(value) when is_number(value) do
    # Kernel.round/1, not Float.round/2 — the latter refuses integers, so
    # rating something an 8 crashed where 8.0 worked.
    rounded = round(value * 2) / 2
    if rounded >= 0.5 and rounded <= 10, do: rounded, else: nil
  end

  def round_half(_value), do: nil

  defp session_id, do: Application.get_env(:laev_app, :tmdb_session)

  @doc "The IMDb id (tt…) for a details map, or nil."
  def imdb_id(details) when is_map(details), do: details["imdb_id"] || get_in(details, ["external_ids", "imdb_id"])
  def imdb_id(_), do: nil

  def poster_url(nil, _size), do: nil
  def poster_url(path, size), do: "#{@image_base}/#{size}#{path}"

  defp normalize(%{"media_type" => type} = r) do
    %{
      id: r["id"],
      type: type,
      title: r["title"] || r["name"],
      year: year(r["release_date"] || r["first_air_date"]),
      overview: r["overview"],
      poster: poster_url(r["poster_path"], "w342"),
      vote: r["vote_average"],
      popularity: r["popularity"]
    }
  end

  def year(nil), do: nil
  def year(""), do: nil
  def year(<<year::binary-size(4), _rest::binary>>), do: year

  defp post(path, body, params \\ []) do
    request(:post, path, params, json: body)
  end

  defp get(path, params \\ []) do
    request(:get, path, params, [])
  end

  defp request(method, path, params, extra) do
    key = key()

    {auth, params} =
      if String.starts_with?(key, "eyJ") do
        {[auth: {:bearer, key}], params}
      else
        {[], Keyword.put(params, :api_key, key)}
      end

    opts = [url: path, params: params, method: method] ++ auth ++ extra

    case Req.request(Req.new(base_url: @base, retry: false), opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:tmdb, status, body["status_message"] || body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp key, do: Application.get_env(:laev_app, :tmdb_key)
end
