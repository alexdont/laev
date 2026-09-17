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
  @index for f <- @franchises,
             e <- f.entries,
             into: %{},
             do: {{e.type, e.tmdb_id}, f}

  @doc "Every curated franchise."
  def all, do: @franchises

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
  The franchise a title belongs to, or `nil`. Takes the shapes the pickers
  already carry — a TMDB search result (`%{type:, id:}`) or a plain id pair.
  """
  def for_title(%{type: type, id: id}), do: lookup(type, id)
  def for_title(%{"type" => type, "tmdb_id" => id}), do: lookup(type, id)
  def for_title(_), do: nil

  def lookup(type, id) when is_binary(type) and is_integer(id), do: Map.get(@index, {type, id})
  def lookup(_, _), do: nil

  @doc """
  The first curated franchise any of these titles belongs to. Search results are
  scanned rather than just the top hit, so a franchise is still offered when the
  best match for the query happens to be something else.
  """
  def detect(titles) when is_list(titles) do
    Enum.find_value(titles, &for_title/1)
  end

  def detect(_), do: nil
end
