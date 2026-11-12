defmodule Laev.Search do
  @moduledoc """
  What a typed query means, and how to order the titles TMDB answers with.

  Pure functions over a query string and a list of TMDB results: no HTTP, no
  scope, no terminal. Laev's `watch` flow and a web app can run the same rules
  in their own way — roki carried a second copy of all of it for exactly this
  reason.

  ## What a query can hold

      iex> Laev.Search.parse("heat 1995")
      %{title: "heat", year: 1995, imdb_id: nil}

      iex> Laev.Search.parse("tt0113277")
      %{title: nil, year: nil, imdb_id: "tt0113277"}

  An IMDb id is not a title search at all — it identifies one film, and the
  caller should look it up rather than search for it.

  ## Spelling

  TMDB does not cross-match British and American spellings: *In the Grey* is
  invisible to a search for "gray". So a query is searched in every variant and
  the pages merged — `variants/1` gives them, and `rank/3` uses `canonical/1`
  to decide what counts as an exact title whichever spelling either side used.

  ## Ordering

  `rank/3` puts an exact title first (newest first, so a remake outranks the
  original it was named after), then everything else by TMDB's popularity. A
  year in the query beats both, softly: an exact year, then within a year —
  release dates move between regions and announcements — then the rest.
  """

  @imdb_id ~r/^\s*(tt\d{6,})\s*$/i
  @trailing_year ~r/^(.*?)\s+((?:19|20)\d{2})\s*$/

  # The pairs worth searching both ways. Only ones where the two spellings are
  # the same word: a list of every -our/-or word would match inside names that
  # have nothing to do with it.
  @spelling_pairs [
    {"gray", "grey"},
    {"color", "colour"},
    {"theater", "theatre"},
    {"harbor", "harbour"},
    {"armor", "armour"},
    {"honor", "honour"}
  ]

  @type parsed :: %{title: String.t() | nil, year: pos_integer() | nil, imdb_id: String.t() | nil}

  @doc """
  What the query asks for: a title, a title and a year, or an IMDb id.

  A four-digit year at the end is taken as a year rather than part of the title
  — "heat 1995" is Heat, not a film called "Heat 1995" — which is worth it for
  how often people type it and costs little: nothing is dropped, the year is
  only a ranking hint.
  """
  @spec parse(String.t()) :: parsed()
  def parse(query) when is_binary(query) do
    case Regex.run(@imdb_id, query) do
      [_, imdb_id] ->
        %{title: nil, year: nil, imdb_id: String.downcase(imdb_id)}

      _ ->
        {title, year} = title_and_year(query)
        %{title: title, year: year, imdb_id: nil}
    end
  end

  def parse(_query), do: %{title: nil, year: nil, imdb_id: nil}

  @doc "The query without its trailing year, and the year, if it had one."
  @spec title_and_year(String.t()) :: {String.t(), pos_integer() | nil}
  def title_and_year(query) when is_binary(query) do
    case Regex.run(@trailing_year, String.trim(query)) do
      [_, rest, year] when rest != "" -> {rest, String.to_integer(year)}
      _ -> {query, nil}
    end
  end

  @doc """
  The spellings to search for, the query itself first.

      iex> Laev.Search.variants("In the Gray")
      ["In the Gray", "in the grey"]

      iex> Laev.Search.variants("Dune")
      ["Dune"]
  """
  @spec variants(String.t()) :: [String.t()]
  def variants(query) when is_binary(query) do
    downcased = String.downcase(query)

    extra =
      Enum.flat_map(@spelling_pairs, fn {a, b} ->
        cond do
          String.contains?(downcased, a) -> [String.replace(downcased, a, b)]
          String.contains?(downcased, b) -> [String.replace(downcased, b, a)]
          true -> []
        end
      end)

    Enum.uniq([query | extra])
  end

  def variants(_query), do: []

  @doc """
  A title reduced to one spelling and one case, for comparing two of them.

      iex> Laev.Search.canonical("  In the Grey ") == Laev.Search.canonical("In the Gray")
      true
  """
  @spec canonical(String.t() | nil) :: String.t()
  def canonical(title) do
    title
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(fn text -> Enum.reduce(@spelling_pairs, text, fn {a, b}, acc -> String.replace(acc, b, a) end) end)
  end

  @doc """
  Order TMDB results for `query`, best first. See the module doc.

  Each result is a map with `:title`, `:year` (a string or an integer, as TMDB
  gives it) and `:popularity`; anything else on it is carried through
  untouched. `year` is the year from the query, or nil.
  """
  @spec rank([map()], String.t() | parsed(), pos_integer() | nil) :: [map()]
  def rank(results, query, year \\ nil)

  # The query as `parse/1` gave it back, which is how a caller that parsed it
  # already should pass it.
  def rank(results, %{title: title, year: year}, _ignored), do: rank(results, title || "", year)

  def rank(results, query, year) when is_list(results) and is_binary(query) do
    wanted = canonical(query)

    Enum.sort_by(results, fn result ->
      released = year_of(result)

      year_rank =
        cond do
          year == nil -> 0
          released == year -> 0
          is_integer(released) and abs(released - year) <= 1 -> 1
          true -> 2
        end

      if canonical(result[:title] || result["title"]) == wanted do
        # Newest first among exact matches: a remake is what somebody typing
        # the name today usually means.
        {year_rank, 0, -(released || 0)}
      else
        {year_rank, 1, -(result[:popularity] || result["popularity"] || 0)}
      end
    end)
  end

  defp year_of(result) do
    case result[:year] || result["year"] do
      year when is_integer(year) -> year
      year when is_binary(year) -> case Integer.parse(year) do
                                     {year, _rest} -> year
                                     _ -> nil
                                   end
      _ -> nil
    end
  end
end
