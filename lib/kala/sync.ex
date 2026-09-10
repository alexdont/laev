defmodule Kala.Sync do
  @moduledoc """
  Optional cross-device sync of user state to a self-hosted endpoint.

  kala is local-first: with no endpoint configured, nothing ever leaves the
  machine (today's behaviour). Set `KALA_SYNC_URL` (+ optional
  `KALA_SYNC_TOKEN`) and kala mirrors its user-state bundle to that URL so a
  second computer or a phone sees the same watchlist, history, resume points
  and watched flags.

  ## The contract with the server

  The server is a **dumb blob store** — it holds one opaque JSON document per
  `(token, doc-name)` pair and nothing more. kala owns *all* merge logic, so
  any client that speaks the same GET/PUT is automatically consistent. The
  token lives in the path; the last segment is a free-form doc name (kala
  keeps everything in one doc):

      GET  <base>/<token>/kala   -> 200 {bundle} (+ ETag), or 404 when empty
      PUT  <base>/<token>/kala   -> 200 (+ new ETag)
                 If-Match: "<etag>"   stale => 412 (no overwrite);
                 unknown token => 401; body > 5 MB => 413

  ## What is synced (and what is deliberately not)

  Synced: watchlist, resume/history, per-episode positions, watched flags,
  and per-series audio/subtitle track choices. Never synced: API keys
  (`config`) or MAL OAuth tokens (`mal.json`) — those are device/secret state,
  not user state.

  ## Merge model

  Everything is per-record **last-write-wins** by `updated_at`. Deletions are
  tombstones (`deleted: true`) so an unpin/unwatch on one device propagates
  instead of being resurrected on the next merge. A local sidecar
  (`sync.json`) remembers the last synced bundle so we can diff the flat data
  files into timestamped changes — including deletions — without every writer
  having to know about sync.

  Every function returns values; sync never raises into the caller.
  """

  @collections [:watchlist, :resume, :positions, :tracks]

  # The whole bundle lives in one document per token. The server treats the
  # last path segment as a free-form doc name — `<base>/<token>/<doc>`.
  @doc_name "kala"

  # ── config ────────────────────────────────────────────────────────

  @doc "The configured base URL (for display), e.g. https://host/kala."
  def url, do: blank_to_nil(Application.get_env(:kala_app, :sync_url))
  def token, do: blank_to_nil(Application.get_env(:kala_app, :sync_token))
  def enabled?, do: url() != nil

  @doc """
  Whether kala syncs automatically (on launch and after each episode).
  Off by default — with sync configured but auto off, state only moves when
  the user runs `kala sync` or the "sync now" menu action. `KALA_SYNC_AUTO`.
  """
  def auto? do
    case Application.get_env(:kala_app, :sync_auto) do
      v when is_binary(v) -> String.downcase(String.trim(v)) in ["on", "true", "yes", "1"]
      _ -> false
    end
  end

  @doc """
  Whether kala pushes each change the moment it happens (a pin, a watched
  flag, a resume point) as a small delta, rather than waiting for the next
  full sync. Off by default. `KALA_SYNC_LIVE`.
  """
  def live? do
    case Application.get_env(:kala_app, :sync_live) do
      v when is_binary(v) -> String.downcase(String.trim(v)) in ["on", "true", "yes", "1"]
      _ -> false
    end
  end

  @doc "Total per-collection changes (max of pulled/pushed) from a summary."
  def change_count(summary) do
    summary |> Map.values() |> Enum.map(fn s -> max(s.pulled, s.pushed) end) |> Enum.sum()
  end

  @doc """
  Push only what changed since the last sync as a delta — used for per-action
  "live" saving. Cheap: when nothing changed it makes no network call. Sends
  just the changed records to the server's merge endpoint; if the server has
  no delta endpoint yet, falls back to a full (safe) sync so nothing is lost.

  Returns `:skip` (disabled/off), `:ok` (nothing to send), `{:ok, n}` (n
  records pushed), a full-sync result, or `{:error, reason}`.
  """
  def live_push do
    if enabled?() and live?(), do: do_live_push(), else: :skip
  end

  defp do_live_push do
    sidecar = load_sidecar()
    local = reconcile(read_local(), sidecar)
    delta = compute_delta(local, sidecar)

    if delta_empty?(delta) do
      :ok
    else
      case push_delta(delta) do
        :ok ->
          save_sidecar(merge(sidecar, delta))
          {:ok, count_delta(delta)}

        :unsupported ->
          # No merge endpoint on the server — fall back to a full, safe sync.
          sync()

        {:error, _} = e ->
          e
      end
    end
  end

  # Records where the local (reconciled) bundle differs from the last-synced
  # sidecar — i.e. exactly what this device changed.
  defp compute_delta(local, sidecar) do
    for coll <- @collections, into: %{} do
      lm = Map.get(local, coll, %{})
      sm = Map.get(sidecar, coll, %{})
      changed = for {k, rec} <- lm, rec != Map.get(sm, k), into: %{}, do: {k, rec}
      {coll, changed}
    end
  end

  defp delta_empty?(delta), do: Enum.all?(delta, fn {_c, m} -> map_size(m) == 0 end)
  defp count_delta(delta), do: delta |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum()

  # The actual GET/PUT target. This server carries the token in the path;
  # when no token is set we fall back to the bare base (bearer-style server).
  defp endpoint do
    base = String.trim_trailing(url(), "/")

    case token() do
      nil -> base
      t -> "#{base}/#{t}/#{@doc_name}"
    end
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil

  # ── public entry points ───────────────────────────────────────────

  @doc """
  Pull → merge → apply → push, once. Returns:

    * `:disabled`        — no endpoint configured
    * `{:ok, summary}`   — a map of per-collection change counts
    * `{:error, reason}` — network / server problem (local state untouched)
  """
  def sync do
    if enabled?(), do: run(), else: :disabled
  end

  @doc "Sync, but only log a one-line result to stderr (used at startup/exit)."
  def sync_quiet(label) do
    case sync() do
      {:ok, summary} ->
        n = change_count(summary)
        if n > 0, do: note("↻ #{label}: #{n} change(s) synced")
        :ok

      {:error, reason} ->
        note("↻ #{label}: offline (#{inspect_short(reason)})")
        :error

      :disabled ->
        :disabled
    end
  end

  # ── orchestration ─────────────────────────────────────────────────

  defp run(retry \\ true) do
    with {:ok, remote, etag} <- pull() do
      sidecar = load_sidecar()
      local = reconcile(read_local(), sidecar)
      remote_b = normalize(remote)
      merged = merge(local, remote_b)

      apply_bundle(merged)
      save_sidecar(merged)

      case push(merged, etag) do
        :ok ->
          {:ok, summary(local, remote_b, merged)}

        {:conflict, _} when retry ->
          # Someone else pushed between our GET and PUT — merge their change in.
          run(false)

        {:conflict, _} ->
          {:error, :conflict}

        {:error, _} = e ->
          e
      end
    end
  end

  # ── HTTP (all the server needs to implement) ──────────────────────

  defp pull do
    case Req.get(endpoint(), headers: auth(), retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body} = resp} when is_map(body) ->
        {:ok, body, etag(resp)}

      {:ok, %{status: s}} when s in [204, 404] ->
        {:ok, %{}, nil}

      {:ok, %{status: 200, body: ""}} ->
        {:ok, %{}, nil}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, inspect_short(b)}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp push(bundle, etag) do
    headers = if etag, do: [{"if-match", etag} | auth()], else: auth()

    case Req.put(endpoint(), headers: headers, json: to_wire(bundle), retry: false, receive_timeout: 15_000) do
      {:ok, %{status: s}} when s in 200..204 -> :ok
      {:ok, %{status: 412}} -> {:conflict, :etag}
      {:ok, %{status: 409}} -> {:conflict, :version}
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, inspect_short(b)}}
      {:error, e} -> {:error, e}
    end
  end

  # Send just the changed records to the server's merge endpoint. The server
  # applies them by last-write-wins into the stored doc — no If-Match needed,
  # since a merge can't clobber a concurrent change. A server without a merge
  # endpoint answers 404/405/501, which we treat as "fall back to full sync".
  defp push_delta(delta) do
    req =
      Req.new(
        method: :patch,
        url: endpoint(),
        headers: auth(),
        json: to_wire(delta),
        retry: false,
        receive_timeout: 15_000
      )

    case Req.request(req) do
      {:ok, %{status: s}} when s in 200..204 -> :ok
      {:ok, %{status: s}} when s in [404, 405, 501] -> :unsupported
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, inspect_short(b)}}
      {:error, e} -> {:error, e}
    end
  end

  defp auth do
    base = [{"content-type", "application/json"}]
    case token() do
      nil -> base
      t -> [{"authorization", "Bearer #{t}"} | base]
    end
  end

  defp etag(%{headers: headers}) do
    case headers do
      %{} = h -> h |> Map.get("etag") |> List.wrap() |> List.first()
      list when is_list(list) -> Enum.find_value(list, fn {k, v} -> if String.downcase(k) == "etag", do: v end)
      _ -> nil
    end
  end

  # ── reading local state into a flat map per collection ────────────
  #
  # Each collection becomes %{key => raw}, where raw is the entry map
  # (watchlist/resume) or the string contents (positions/tracks).

  defp read_local do
    %{
      watchlist: read_json_map(Path.join(data_dir(), "watchlist.json")),
      resume: read_json_map(Path.join(data_dir(), "resume.json")),
      positions: read_dir(Path.join(data_dir(), "positions")),
      tracks: read_dir(Path.join(data_dir(), "tracks"))
    }
  end

  defp read_json_map(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp read_dir(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, into: %{} do
          {name, File.read(Path.join(dir, name)) |> case(do: ({:ok, b} -> String.trim(b); _ -> ""))}
        end

      _ ->
        %{}
    end
  end

  # ── reconcile flat local state against the last-synced sidecar ─────
  #
  # Produces a timestamped bundle: %{collection => %{key => record}} where a
  # record is %{"data" => raw, "updated_at" => secs, "deleted" => bool}.

  defp reconcile(current, sidecar) do
    now = now()

    for coll <- @collections, into: %{} do
      cur = Map.get(current, coll, %{})
      old = get_in(sidecar, [coll]) || %{}
      keys = MapSet.union(MapSet.new(Map.keys(cur)), MapSet.new(Map.keys(old)))

      recs =
        for key <- keys, into: %{} do
          {key, reconcile_one(coll, key, Map.get(cur, key), Map.get(old, key), now)}
        end

      {coll, recs}
    end
  end

  defp reconcile_one(coll, key, cur, old, now) do
    cond do
      # Present locally, unknown before → new record.
      not is_nil(cur) and is_nil(old) ->
        %{"data" => cur, "updated_at" => initial_ts(coll, key, cur, now), "deleted" => false}

      # Present locally, previously tombstoned → re-added.
      not is_nil(cur) and old["deleted"] ->
        %{"data" => cur, "updated_at" => now, "deleted" => false}

      # Present both → unchanged keeps its timestamp; edited bumps to now.
      not is_nil(cur) ->
        if cur == old["data"],
          do: old,
          else: %{"data" => cur, "updated_at" => now, "deleted" => false}

      # Gone locally but known before and not yet tombstoned → tombstone now.
      is_nil(cur) and old && not old["deleted"] ->
        %{"data" => old["data"], "updated_at" => now, "deleted" => true}

      # Gone locally, already tombstoned → keep the tombstone.
      true ->
        old
    end
  end

  # Seed a record's first timestamp from data it already carries, so first-time
  # sync between two machines with pre-existing history merges sensibly.
  defp initial_ts(:watchlist, _key, %{"added_at" => t}, _now) when is_integer(t), do: t
  defp initial_ts(:resume, _key, %{"updated_at" => t}, _now) when is_integer(t), do: t
  defp initial_ts(_coll, _key, _data, now), do: now

  # ── merge two timestamped bundles (last-write-wins) ───────────────

  defp merge(a, b) do
    for coll <- @collections, into: %{} do
      am = Map.get(a, coll, %{})
      bm = Map.get(b, coll, %{})
      keys = MapSet.union(MapSet.new(Map.keys(am)), MapSet.new(Map.keys(bm)))

      recs =
        for key <- keys, into: %{} do
          {key, pick(Map.get(am, key), Map.get(bm, key))}
        end

      {coll, recs}
    end
  end

  defp pick(nil, b), do: b
  defp pick(a, nil), do: a
  # Higher updated_at wins; local (a) wins exact ties for determinism.
  defp pick(a, b), do: if(ts(a) >= ts(b), do: a, else: b)

  defp ts(%{"updated_at" => t}) when is_integer(t), do: t
  defp ts(_), do: 0

  # ── apply a merged bundle back to the flat local files ────────────

  defp apply_bundle(merged) do
    write_json_map(Path.join(data_dir(), "watchlist.json"), live(merged, :watchlist))
    write_json_map(Path.join(data_dir(), "resume.json"), live(merged, :resume))
    apply_dir(Path.join(data_dir(), "positions"), merged[:positions] || %{})
    apply_dir(Path.join(data_dir(), "tracks"), merged[:tracks] || %{})
    :ok
  end

  # Non-deleted records of a collection as key => data.
  defp live(merged, coll) do
    for {k, rec} <- Map.get(merged, coll, %{}), not rec["deleted"], into: %{}, do: {k, rec["data"]}
  end

  defp write_json_map(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
  rescue
    _ -> :ok
  end

  defp apply_dir(dir, recs) do
    File.mkdir_p!(dir)

    for {key, rec} <- recs do
      path = Path.join(dir, key)

      if rec["deleted"],
        do: File.rm(path),
        else: File.write(path, to_string(rec["data"]))
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── sidecar (last-synced bundle) ──────────────────────────────────

  defp sidecar_path, do: Path.join(data_dir(), "sync.json")

  defp load_sidecar do
    with {:ok, body} <- File.read(sidecar_path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      normalize(map)
    else
      _ -> %{}
    end
  end

  defp save_sidecar(bundle) do
    File.mkdir_p!(data_dir())
    File.write(sidecar_path(), Jason.encode!(to_wire(bundle)))
  rescue
    _ -> :ok
  end

  # ── wire format helpers ───────────────────────────────────────────

  # JSON object keys come back as strings; normalize collection keys to atoms.
  defp normalize(bundle) when is_map(bundle) do
    for coll <- @collections, into: %{} do
      {coll, Map.get(bundle, Atom.to_string(coll)) || Map.get(bundle, coll) || %{}}
    end
  end

  defp normalize(_), do: %{}

  defp to_wire(bundle) do
    Map.put(for(coll <- @collections, into: %{}, do: {Atom.to_string(coll), Map.get(bundle, coll, %{})}), "version", 1)
  end

  # ── misc ──────────────────────────────────────────────────────────

  # Per-collection stats: `pulled` = records this device gained from the
  # server, `pushed` = records the server gained from us, `total` = live
  # (non-deleted) records now.
  defp summary(local, remote, merged) do
    for coll <- @collections, into: %{} do
      m = Map.get(merged, coll, %{})
      l = Map.get(local, coll, %{})
      r = Map.get(remote, coll, %{})

      pulled = Enum.count(m, fn {k, rec} -> rec != Map.get(l, k) end)
      pushed = Enum.count(m, fn {k, rec} -> rec != Map.get(r, k) end)

      {coll,
       %{
         pulled: pulled,
         pushed: pushed,
         total: live_count(m),
         local: live_count(l),
         server: live_count(r)
       }}
    end
  end

  # Live (non-deleted) records in a collection map.
  defp live_count(m), do: Enum.count(m, fn {_k, rec} -> rec["deleted"] != true end)

  defp data_dir do
    Application.get_env(:kala_app, :data_dir) || Path.join(System.user_home!(), ".kala")
  end

  defp now, do: System.os_time(:second)

  defp note(msg), do: IO.puts(:stderr, IO.ANSI.format([:faint, "  #{msg}", :reset]))

  defp inspect_short(term) do
    term |> inspect() |> String.slice(0, 80)
  end
end
