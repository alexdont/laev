defmodule Laev.Franchises do
  @moduledoc """
  Hand-curated franchises, for the ones TMDB groups badly.

  TMDB's own collections are right for most of them — John Wick, Star Wars,
  Jurassic Park — and those need nothing here: the app falls back to the
  collection and gets the same result for free. This file is only for the
  exceptions, where a franchise is split across several collections (Alien sits
  in four), where the collection is missing films (The War of the Rohirrim), or
  where part of it isn't a film at all (Alien: Earth is a TV series, and TMDB
  files it under no franchise at all).

  Membership is by TMDB id, so searching *any* member offers the whole
  franchise: "order of the phoenix" finds the Harry Potter list just as
  "harry potter" does.

  A show that ran across several years is listed one season at a time, each
  dated by when it aired. That is what keeps release order honest: Agents of
  S.H.I.E.L.D. season 1 belongs between The Avengers and Iron Man 3, not as a
  single 2013 row that would have someone watch seven seasons before returning
  to the films of 2014.

  The data is read at compile time, so looking a title up costs nothing at
  runtime and works offline. Editing `priv/franchises.json` recompiles this
  module.
  """

  @external_resource Path.join([__DIR__, "..", "..", "priv", "franchises.json"])

  @franchises @external_resource
              |> File.read!()
              |> Jason.decode!()
              |> Map.fetch!("franchises")
              |> Enum.map(fn f ->
                %{
                  name: f["name"],
                  tiers: Enum.map(f["tiers"] || [], &%{key: &1["key"], label: &1["label"], blurb: &1["blurb"]}),
                  entries:
                    f["entries"]
                    |> Enum.map(
                      &%{
                        type: &1["type"],
                        tmdb_id: &1["tmdb_id"],
                        season: &1["season"],
                        title: &1["title"],
                        date: &1["date"],
                        tiers: &1["tiers"] || []
                      }
                    )
                    # release order, with the not-yet-dated last
                    |> Enum.sort_by(&if(&1.date in [nil, ""], do: "9999", else: &1.date))
                }
              end)

  # {type, tmdb_id} => franchise, so a lookup is a map fetch rather than a scan.
  #
  # A title can sit in more than one list — Logan is both an X-Men film and a
  # Marvel one — and the smaller list is the more useful answer: someone looking
  # up Logan wants the fourteen X-Men films, not all 169 Marvel titles. Iron Man
  # is in no smaller list, so it still opens Marvel.
  @index @franchises
         |> Enum.flat_map(fn f -> Enum.map(f.entries, &{{&1.type, &1.tmdb_id}, f}) end)
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
         |> Map.new(fn {key, franchises} -> {key, Enum.sort_by(franchises, &length(&1.entries))} end)

  @doc "Every curated franchise."
  def all, do: @franchises

  @doc "A curated franchise by name — how a pinned one is found again."
  def by_name(name), do: Enum.find(@franchises, &(&1.name == name))

  @doc """
  Whether a franchise offers more than one way to watch it. Only the big ones
  need it — a catalogue of sixty-odd titles is not something to hand someone
  flat, while seven Middle-earth films are.
  """
  def tiered?(%{tiers: tiers}), do: tiers != []

  @doc ~S"""
  The entries in one tier, in release order. `"all"` — and any franchise
  without tiers — is everything.
  """
  def entries(franchise, tier \\ "all")
  def entries(%{entries: entries}, "all"), do: entries
  def entries(%{entries: entries}, tier), do: Enum.filter(entries, &(tier in &1.tiers))

  @doc "A tier's label, for a header."
  def tier_label(%{tiers: tiers}, key) do
    case Enum.find(tiers, &(&1.key == key)) do
      nil -> nil
      tier -> tier.label
    end
  end

  @doc """
  Every curated franchise a title belongs to, smallest first. A film is often in
  two — Spider-Man is both its own franchise and part of Marvel — and both are
  worth offering: one is the eight films someone means, the other is the whole
  universe around them.
  """
  def all_for_title(%{type: type, id: id}), do: lookup_all(type, id)
  def all_for_title(%{"type" => type, "tmdb_id" => id}), do: lookup_all(type, id)
  def all_for_title(_), do: []

  def lookup_all(type, id) when is_binary(type) and is_integer(id), do: Map.get(@index, {type, id}, [])
  def lookup_all(_, _), do: []

  @doc "The most specific franchise a title belongs to, or `nil`."
  def for_title(title), do: List.first(all_for_title(title))

  def lookup(type, id), do: List.first(lookup_all(type, id))

  @doc """
  Every curated franchise these titles belong to, smallest first. Search results
  are scanned rather than just the top hit, so a franchise is still offered when
  the best match for the query happens to be something else.
  """
  def detect(titles) when is_list(titles) do
    titles
    |> Enum.flat_map(&all_for_title/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(&length(&1.entries))
  end

  def detect(_), do: []
end
