defmodule Laev.NowPlaying do
  @moduledoc """
  Whether mpv is still playing something laev started, and what.

  mpv is launched detached, so laev can leave its Now Playing page — esc goes
  back to the menu and the film keeps running. That is the whole point, but it
  used to be one-way: nothing led back, and the page holds the things you want
  mid-film (rate it, switch source, queue the next episode).

  A launch records what it started; liveness is read back from the tracker's
  own heartbeat. The mpv script rewrites `played/<key>` every 5 seconds for as
  long as the player is up — pause included, since a paused mpv still reports
  a position — so a recent write means mpv is alive, and nothing to write
  means it is gone. That file is deliberately the signal rather than the
  position file: positions are synced, and a sync pull rewrites all of them at
  once, which would make every title look like it just played.
  """

  @filename "now_playing.json"
  # Three heartbeats' grace. Long enough to ride out a stalled write, short
  # enough that a closed player disappears from the menu while you are still
  # looking at it.
  @stale_after 16

  @doc "Record what was just launched. Best-effort: never breaks playback."
  def mark(ctx, stream) when is_map(ctx) do
    File.write(
      path(),
      Jason.encode!(%{
        "ctx" => Map.new(ctx, fn {k, v} -> {to_string(k), v} end),
        "url" => Map.get(stream, :url),
        "filename" => Map.get(stream, :filename),
        "at" => System.os_time(:second)
      })
    )

    :ok
  rescue
    _ -> :ok
  end

  def mark(_ctx, _stream), do: :ok

  @doc "Forget it — the player is gone, or the user quit laev with it."
  def clear do
    File.rm(path())
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  What mpv is playing right now as `{ctx, stream}`, or nil when nothing is.

  The stream half can be all nils for a play recorded before this existed;
  the page copes, because everything but "replay" works from the context.
  """
  def current, do: current(mpv_running?())

  @doc false
  # Split so the rule can be tested without a player on the machine.
  def current(mpv_running?) do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"ctx" => raw} = saved} <- Jason.decode(body),
         ctx when is_map(ctx) <- to_ctx(raw),
         true <- mpv_running?,
         true <- fresh?(Laev.Position.heartbeat_at(ctx)) do
      {ctx, %{url: saved["url"], filename: saved["filename"]}}
    else
      _ -> nil
    end
  end

  # Alive if the tracker wrote recently. mpv's own process is checked too
  # where pgrep exists, so a machine that slept through the staleness window
  # doesn't come back claiming a film is still on.
  defp fresh?(nil), do: false
  defp fresh?(at), do: System.os_time(:second) - at <= @stale_after

  defp mpv_running? do
    case System.find_executable("pgrep") do
      nil -> true
      pgrep -> match?({_, 0}, System.cmd(pgrep, ["-x", "mpv"], stderr_to_stdout: true))
    end
  rescue
    _ -> true
  end

  # Back to the atom-keyed shape the play flow uses everywhere else.
  defp to_ctx(%{"type" => type, "tmdb_id" => id} = raw) when type in ["movie", "tv"] and is_integer(id) do
    %{
      type: type,
      tmdb_id: id,
      title: raw["title"],
      season: raw["season"],
      episode: raw["episode"],
      poster_path: raw["poster_path"],
      anime: raw["anime"] || false,
      search_title: raw["search_title"]
    }
  end

  defp to_ctx(_), do: nil

  defp path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    File.mkdir_p(dir)
    Path.join(dir, @filename)
  end
end
