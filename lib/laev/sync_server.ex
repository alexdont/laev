defmodule Laev.SyncServer do
  @moduledoc """
  The server half of sync, for whoever wants to host it.

  The hosted store has now lived in two different applications, each with its
  own copy of the same merge rules — and the rules are the part that must not
  drift, because a client that merges differently from the server loses
  somebody's watchlist. So they live here, next to the client that depends on
  them, and a host supplies only storage and routing.

  What is deliberately *not* here: the HTTP layer. laev is a command-line
  application and a client library; making it depend on Plug so that it could
  also be a web server would put a router inside every terminal install. A host
  already has routing, and the handler is a few lines over these functions —
  `token_ok?/1`, `plausible?/1`, `etag/1`, `merge/2` — with the one rule that
  matters repeated here because it is easy to get wrong: **store the raw request
  bytes.** A document is returned byte for byte, so re-encoding the parsed JSON
  is a different document — key order, spacing and number formatting all change
  — and every ETag comparison after it is wrong.

  The protocol, which clients depend on and which must not change:

      GET   <base>/<key>/<doc>  → 200 + stored bytes + ETag, or 404
      PUT   <base>/<key>/<doc>  → stores bytes verbatim, 200 + ETag
                                  stale If-Match → 412, nothing written
      PATCH <base>/<key>/<doc>  → merges a partial bundle, 200 + ETag

      malformed key → 401 · not laev-shaped → 422 · over #{5} MB → 413
  """

  @max_bytes 5 * 1024 * 1024
  @token_format ~r/^laev_[A-Za-z0-9_-]{30,64}$/
  @collections ~w(watchlist resume positions tracks)
  # A document carrying any one of these is laev's. Extra keys are fine — the
  # client gained holds, anime and seasons after this list was written, and a
  # server that rejected them would have broken every new client.
  @markers ~w(version watchlist resume positions tracks)

  @doc "The largest document accepted, in bytes."
  def max_bytes, do: @max_bytes

  @doc "The collections whose records are merged record by record."
  def collections, do: @collections

  @doc """
  Does this look like a laev key?

  A format check, not a guest list: any well-formed key is its own tenant, so
  nobody has to be registered to sync. The format is the gate — `laev_` and at
  least thirty characters of URL-safe randomness is not something a scanner
  emits by accident. Only `sha256(key)` should ever be stored.
  """
  def token_ok?(token) when is_binary(token), do: Regex.match?(@token_format, token)
  def token_ok?(_token), do: false

  @doc """
  Is this body plausibly a laev document?

  Validation only — what gets stored is always the raw bytes, never a
  re-encoding of this parse.
  """
  def plausible?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> Enum.any?(@markers, &Map.has_key?(map, &1))
      _ -> false
    end
  end

  def plausible?(_body), do: false

  @doc """
  The ETag for a document: the sha256 of its bytes, so identical bytes always
  give an identical tag and no state has to be kept to compare them.
  """
  def etag(body) when is_binary(body),
    do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  @doc "What to store instead of the key itself."
  def token_hash(token) when is_binary(token),
    do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  @doc """
  An If-Match header value as a bare ETag — quotes and a weak marker removed.
  """
  def parse_if_match([value | _]), do: parse_if_match(value)

  def parse_if_match(value) when is_binary(value) do
    value |> String.trim() |> String.replace_prefix("W/", "") |> String.trim(~s("))
  end

  def parse_if_match(_value), do: nil

  @doc """
  Merge a partial bundle into a stored document, and give back the merged map.

  This is the one place the server understands the record shape; GET and PUT
  stay opaque. Per collection, per record: last write wins on `updated_at`, and
  a tie goes to the incoming one. Tombstones (`deleted: true`) are stored as
  they are, because a deletion has to reach the other devices — dropping them
  is how an unpinned title comes back. Anything the patch does not mention is
  untouched, and unknown top-level keys are copied over whole so a newer client
  can carry something this server has never heard of.

  `{:ok, merged}` or `{:error, :invalid}` when a named collection is not a map
  of records.

  The caller must serialise this per (key, doc) — a transaction with an advisory
  lock, or whatever its storage offers. Read-modify-write without it loses
  updates, which is a bug nobody sees until two devices sync at once.
  """
  def merge(stored, patch) when is_map(stored) and is_map(patch) do
    if collections_ok?(patch), do: {:ok, merge_docs(stored, patch)}, else: {:error, :invalid}
  end

  def merge(_stored, _patch), do: {:error, :invalid}

  @doc "The same merge, taking and returning JSON text."
  def merge_json(stored_body, patch_body) do
    with {:ok, patch} <- decode_object(patch_body),
         {:ok, merged} <- merge(decode_object!(stored_body), patch) do
      {:ok, Jason.encode!(merged)}
    end
  end

  defp collections_ok?(patch) do
    Enum.all?(@collections, fn collection ->
      case patch[collection] do
        nil -> true
        %{} -> true
        _ -> false
      end
    end)
  end

  defp merge_docs(stored, patch) do
    Enum.reduce(patch, stored, fn
      {collection, incoming}, acc when is_map(incoming) ->
        if collection in @collections do
          Map.update(acc, collection, incoming, &merge_collection(&1, incoming))
        else
          Map.put(acc, collection, incoming)
        end

      {"version", version}, acc ->
        Map.update(acc, "version", version, fn old ->
          if is_number(old) and is_number(version), do: max(old, version), else: version
        end)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp merge_collection(existing, incoming) when is_map(existing) do
    Enum.reduce(incoming, existing, fn {key, record}, acc ->
      case acc do
        %{^key => current} ->
          if timestamp(record) >= timestamp(current), do: Map.put(acc, key, record), else: acc

        _ ->
          Map.put(acc, key, record)
      end
    end)
  end

  # A stored collection that is not a map — a client wrote something odd through
  # PUT — is replaced rather than crashed on.
  defp merge_collection(_existing, incoming), do: incoming

  defp timestamp(%{"updated_at" => at}) when is_number(at), do: at
  defp timestamp(_record), do: 0

  defp decode_object(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :invalid}
    end
  end

  defp decode_object(_body), do: {:error, :invalid}

  defp decode_object!(body) do
    case decode_object(body) do
      {:ok, map} -> map
      _ -> %{}
    end
  end
end
