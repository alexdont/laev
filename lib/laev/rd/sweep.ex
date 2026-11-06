defmodule Laev.RD.Sweep do
  @moduledoc """
  Clears the strays a probe leaves in the Real-Debrid account.

  `Laev.RD.Ledger` deletes what a dying probe abandons, but it can only do that
  while laev is running: a window closed, a Ctrl-C at the wrong moment or a
  machine put to sleep takes the monitors with it. What is left over is on
  disk, and this is the pass that finishes the job on the next run.

  Deliberately narrow, because it deletes from somebody's account:

    * `error` — the provider could not take the magnet. Nothing to come back to.
    * `magnet_conversion` older than ten minutes — a magnet it never resolved.
      The age matters: one just added belongs to a probe still running.
    * `downloading` / `queued` whose id this laev recorded and abandoned. These
      are the expensive ones — a probe that lost its race left the provider
      fetching a file nobody will ever watch.

  And never:

    * anything `downloaded` — it is cached, it plays instantly, and it is the
      one thing worth keeping;
    * any torrent whose infohash is in the resume history, whatever its status
      — a download *you* started and are waiting on looks exactly like an
      abandoned one from here, and losing it would be laev cancelling your own
      download.
  """

  alias Laev.RD

  @stale_conversion 10 * 60
  @every 6 * 60 * 60
  @stamp "rd_sweep_at"

  @doc """
  Sweep now. Returns `%{deleted: [{id, filename, reason}], kept: n}`, or
  `:disabled` without a token / with `LAEV_RD_SWEEP=off`.
  """
  def run(opts \\ []) do
    if enabled?() do
      abandoned = Laev.RD.Ledger.abandoned()
      protected = protected_hashes()

      case RD.torrents(limit: Keyword.get(opts, :limit, 200)) do
        {:ok, torrents} ->
          {doomed, kept} =
            Enum.split_with(torrents, fn t -> reason(t, abandoned, protected) != nil end)

          deleted =
            for t <- doomed do
              RD.delete_torrent(t["id"])
              {t["id"], t["filename"], reason(t, abandoned, protected)}
            end

          Laev.RD.Ledger.settle(Enum.map(deleted, fn {id, _name, _why} -> id end))
          stamp()
          %{deleted: deleted, kept: length(kept)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :disabled
    end
  end

  @doc """
  Sweep in the background, at most once every six hours. Never blocks, never
  speaks.

  Deletes from a real account, so it is opt-out-able in two places: the user's
  `LAEV_RD_SWEEP=off`, and `config :laev, :sweep_on_boot, false` for a host
  that would rather choose its own moment. The test suite sets the second one:
  starting the app must never reach into somebody's account.
  """
  def warm do
    if on_boot?() and enabled?() and due?() do
      Laev.Scope.spawn(fn ->
        try do
          run()
        rescue
          _ -> :ok
        end
      end)
    end

    :ok
  end

  @doc false
  def reason(torrent, abandoned, protected) do
    hash = torrent["hash"] |> to_string() |> String.downcase()
    status = torrent["status"]

    cond do
      MapSet.member?(protected, hash) -> nil
      status == "downloaded" -> nil
      status == "error" -> :error
      status == "magnet_conversion" and age(torrent) > @stale_conversion -> :never_converted
      status in ["downloading", "queued"] and torrent["id"] in abandoned -> :abandoned_download
      true -> nil
    end
  end

  @doc false
  def due? do
    case File.read(stamp_path()) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {at, _} -> System.os_time(:second) - at > @every
          _ -> true
        end

      _ ->
        true
    end
  end

  # Everything the history points at, whatever state the provider has it in.
  defp protected_hashes do
    for entry <- Laev.Resume.all(),
        hash = entry["source"]["hash"],
        is_binary(hash),
        into: MapSet.new(),
        do: String.downcase(hash)
  rescue
    _ -> MapSet.new()
  end

  defp age(torrent) do
    case DateTime.from_iso8601(to_string(torrent["added"])) do
      {:ok, added, _} -> DateTime.diff(DateTime.utc_now(), added, :second)
      # No timestamp to judge by: treat it as young, which is the safe end.
      _ -> 0
    end
  end

  defp on_boot?, do: Application.get_env(:laev, :sweep_on_boot, true)

  defp enabled? do
    RD.configured?() and
      case Laev.Scope.get(:rd_sweep) do
        v when is_binary(v) -> String.downcase(String.trim(v)) not in ["off", "false", "no", "0"]
        _ -> true
      end
  end

  defp stamp do
    File.mkdir_p(Path.dirname(stamp_path()))
    File.write(stamp_path(), Integer.to_string(System.os_time(:second)))
    :ok
  rescue
    _ -> :ok
  end

  defp stamp_path, do: Path.join(Laev.Scope.dir(), @stamp)
end
