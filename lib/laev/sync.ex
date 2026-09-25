defmodule Laev.Sync do
  @moduledoc """
  Optional cross-device sync of user state to a self-hosted endpoint.

  laev is local-first: with no endpoint configured, nothing ever leaves the
  machine (today's behaviour). Set `LAEV_SYNC_URL` (+ optional
  `LAEV_SYNC_TOKEN`) and laev mirrors its user-state bundle to that URL so a
  second computer or a phone sees the same watchlist, history, resume points
  and watched flags.

  ## The contract with the server

  The server is a **dumb blob store** — it holds one opaque JSON document per
  `(token, doc-name)` pair and nothing more. laev owns *all* merge logic, so
  any client that speaks the same GET/PUT is automatically consistent. The
  token lives in the path; the last segment is a free-form doc name (laev
  keeps everything in one doc):

      GET  <base>/<token>/laev   -> 200 {bundle} (+ ETag), or 404 when empty
      PUT  <base>/<token>/laev   -> 200 (+ new ETag)
                 If-Match: "<etag>"   stale => 412 (no overwrite);
                 unknown token => 401; body > 5 MB => 413

  ## What is synced (and what is deliberately not)

  Synced: watchlist, resume/history, per-episode positions, watched flags,
  and per-series audio/subtitle track choices. Optionally (`LAEV_SYNC_KEYS`)
  also the API keys, encrypted — see "Secrets" below. Never synced: MAL OAuth
  tokens (`mal.json`), because the refresh token rotates on every refresh and
  two machines sharing one would log each other out.

  ## Secrets

  A laev key is `laev_<token>.<secret>`. The token half is the path segment the
  server files the document under, so the server necessarily knows it; the
  secret half never leaves the machine, and is what the API keys are encrypted
  with (AES-256-GCM, key derived by PBKDF2). That split is the whole point: the
  server — or a stolen backup of one — holds ciphertext it has no way to open,
  while the user still has a single string to paste on a new machine.

  Which keys travel is `Laev.Config.syncable_keys/0`, i.e. everything laev
  knows about minus the sync settings themselves and the two machine-specific
  ones, so a provider added later is carried without touching this module.

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
  @doc_name "laev"

  # ── config ────────────────────────────────────────────────────────

  @doc "The configured base URL (for display), e.g. https://host/laev."
  def url, do: blank_to_nil(Application.get_env(:laev_app, :sync_url))
  def enabled?, do: url() != nil

  @doc """
  The half of the laev key the server sees. A key is `laev_<token>.<secret>`;
  only the part before the dot ever goes on the wire, as the path segment that
  identifies the document. Keys issued before the secret existed have no dot
  and are returned whole.
  """
  def token do
    case raw_token() do
      nil -> nil
      raw -> raw |> String.split(".", parts: 2) |> hd() |> blank_to_nil()
    end
  end

  @doc """
  The half that never leaves this machine — it encrypts the API keys, so the
  server must not be able to derive it. `nil` for a key issued without one.
  """
  def secret do
    case raw_token() do
      nil ->
        nil

      raw ->
        case String.split(raw, ".", parts: 2) do
          [_, secret] -> blank_to_nil(secret)
          _ -> nil
        end
    end
  end

  @doc "Whether the laev key also carries the API keys (`LAEV_SYNC_KEYS`)."
  def keys_enabled? do
    secret() != nil and
      case Application.get_env(:laev_app, :sync_keys) do
        v when is_binary(v) -> String.downcase(String.trim(v)) in ["on", "true", "yes", "1"]
        _ -> false
      end
  end

  @doc """
  The whole laev key as the user holds it — both halves. This is what gets
  shown, copied and pasted; `token/0` is the only part that goes to a server.
  """
  def laev_key, do: raw_token()

  defp raw_token, do: blank_to_nil(Application.get_env(:laev_app, :sync_token))

  @doc """
  Whether laev syncs automatically (on launch and after each episode).
  Off by default — with sync configured but auto off, state only moves when
  the user runs `laev sync` or the "sync now" menu action. `LAEV_SYNC_AUTO`.
  """
  def auto? do
    case Application.get_env(:laev_app, :sync_auto) do
      v when is_binary(v) -> String.downcase(String.trim(v)) in ["on", "true", "yes", "1"]
      _ -> false
    end
  end

  @doc """
  Whether laev pushes each change the moment it happens (a pin, a watched
  flag, a resume point) as a small delta, rather than waiting for the next
  full sync. Off by default. `LAEV_SYNC_LIVE`.
  """
  def live? do
    case Application.get_env(:laev_app, :sync_live) do
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

      {secrets, restored} = sync_secrets(remote["secrets"], sidecar_meta())
      if restored > 0, do: note("↓ restored #{restored} key(s) from your laev key")
      save_sidecar(merged, secrets_meta(secrets))

      case push(merged, secrets, etag) do
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

  defp push(bundle, secrets, etag) do
    headers = if etag, do: [{"if-match", etag} | auth()], else: auth()

    case Req.put(endpoint(), headers: headers, json: to_wire(bundle, secrets), retry: false, receive_timeout: 15_000) do
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

    # Watchlist and resume are cached in ETS at boot — without a reload the
    # continue page keeps showing pre-sync state, and the next put/persist
    # would write that stale table back over the synced files (turning the
    # pulled records into tombstones on the sync after that).
    Laev.Resume.reload()
    Laev.Watchlist.reload()
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

  defp save_sidecar(bundle, meta \\ %{}) do
    File.mkdir_p!(data_dir())
    File.write(sidecar_path(), Jason.encode!(Map.merge(to_wire(bundle), meta)))
  rescue
    _ -> :ok
  end

  # The sidecar as stored, including the secrets bookkeeping that normalize/1
  # (which only knows about collections) would drop.
  defp sidecar_meta do
    with {:ok, body} <- File.read(sidecar_path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  # ── wire format helpers ───────────────────────────────────────────

  # JSON object keys come back as strings; normalize collection keys to atoms.
  defp normalize(bundle) when is_map(bundle) do
    for coll <- @collections, into: %{} do
      {coll, Map.get(bundle, Atom.to_string(coll)) || Map.get(bundle, coll) || %{}}
    end
  end

  defp normalize(_), do: %{}

  defp to_wire(bundle, secrets \\ nil) do
    wire = Map.put(for(coll <- @collections, into: %{}, do: {Atom.to_string(coll), Map.get(bundle, coll, %{})}), "version", 1)

    if is_map(secrets), do: Map.put(wire, "secrets", secrets), else: wire
  end

  # ── secrets (the API keys, encrypted) ─────────────────────────────

  @aad "laev-secrets-v1"
  @kdf_iterations 100_000

  # Whole-blob last-write-wins, decided against the digest recorded at the last
  # sync: a digest that no longer matches means the keys were changed here, and
  # a stamp newer than the one we recorded means they were changed elsewhere.
  # Returns the blob to store and how many keys were applied locally.
  defp sync_secrets(remote_blob, meta) do
    if keys_enabled?() do
      resolve_secrets(Laev.Config.export(), decrypt_secrets(remote_blob), remote_blob, meta)
    else
      # Leave whatever is stored alone. A machine with the feature off, or
      # holding an older key with no secret half, must not blank out the keys
      # the other machines rely on.
      {remote_blob, 0}
    end
  end

  # Nothing readable came back. A blob that is *there* but won't open was
  # written with a different secret half, so it belongs to keys we can't see —
  # keep it exactly as it is. Replacing it with ours (or with nothing, on a
  # machine that has no keys yet) would destroy another device's only copy.
  defp resolve_secrets(local, nil, remote_blob, _meta) do
    cond do
      is_map(remote_blob) -> {remote_blob, 0}
      map_size(local) == 0 -> {nil, 0}
      true -> {encrypt_secrets(local), 0}
    end
  end

  defp resolve_secrets(local, remote, remote_blob, meta) do
    last_digest = meta["secrets_digest"]
    remote_ts = (is_map(remote_blob) && remote_blob["updated_at"]) || 0

    cond do
      # Never synced secrets on this machine — the restore path on a fresh
      # install. Adopt what is stored, keep anything only this machine has.
      is_nil(last_digest) ->
        {encrypt_secrets(Map.merge(local, remote)), Laev.Config.import_keys(remote)}

      # Changed here since the last sync: ours win, theirs fill the gaps.
      digest(local) != last_digest ->
        restored = Laev.Config.import_keys(Map.drop(remote, Map.keys(local)))
        {encrypt_secrets(Map.merge(remote, local)), restored}

      remote_ts > (meta["secrets_updated_at"] || 0) ->
        {remote_blob, Laev.Config.import_keys(remote)}

      true ->
        {remote_blob, 0}
    end
  end

  # Bookkeeping for the sidecar: what the key set looks like now, and the stamp
  # on the blob that says so.
  defp secrets_meta(blob) do
    %{
      "secrets_digest" => if(keys_enabled?(), do: digest(Laev.Config.export())),
      "secrets_updated_at" => (is_map(blob) && blob["updated_at"]) || 0
    }
  end

  defp encrypt_secrets(plain) when map_size(plain) == 0, do: nil

  defp encrypt_secrets(plain) do
    with secret when is_binary(secret) <- secret() do
      salt = :crypto.strong_rand_bytes(16)
      iv = :crypto.strong_rand_bytes(12)
      key = derive_key(secret, salt, @kdf_iterations)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Jason.encode!(plain), @aad, true)

      %{
        "v" => 1,
        "kdf" => "pbkdf2-sha256",
        "iter" => @kdf_iterations,
        "salt" => Base.encode64(salt),
        "iv" => Base.encode64(iv),
        "tag" => Base.encode64(tag),
        "data" => Base.encode64(ciphertext),
        "updated_at" => now()
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decrypt_secrets(blob) when is_map(blob) do
    with secret when is_binary(secret) <- secret(),
         {:ok, ciphertext} <- Base.decode64(blob["data"] || ""),
         {:ok, iv} <- Base.decode64(blob["iv"] || ""),
         {:ok, tag} <- Base.decode64(blob["tag"] || ""),
         {:ok, salt} <- Base.decode64(blob["salt"] || ""),
         key = derive_key(secret, salt, blob["iter"] || @kdf_iterations),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false),
         {:ok, map} when is_map(map) <- Jason.decode(plain) do
      map
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decrypt_secrets(_), do: nil

  # Deriving is the expensive part, so hold it for the session — in live mode a
  # sync runs after every action.
  defp derive_key(secret, salt, iterations) do
    cache = {:laev_sync_key, salt, iterations}

    case Process.get(cache) do
      nil ->
        key = :crypto.pbkdf2_hmac(:sha256, secret, salt, iterations, 32)
        Process.put(cache, key)
        key

      key ->
        key
    end
  end

  # Order-independent fingerprint of the key set, so "did this change here?"
  # never turns on map iteration order.
  defp digest(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&Tuple.to_list/1)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
    Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
  end

  defp now, do: System.os_time(:second)

  # Dropped rather than printed while a picker owns the screen — see Laev.Quiet.
  # Sync notes arrive from a background process five seconds after a film ends,
  # which is exactly when the post-play menu is up.
  defp note(msg), do: Laev.Quiet.puts(IO.ANSI.format([:faint, "  #{msg}", :reset]))

  defp inspect_short(term) do
    term |> inspect() |> String.slice(0, 80)
  end
end
