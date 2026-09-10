defmodule Laev.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    migrate_from_old_names()
    Laev.Config.load()
    Laev.Blocklist.init()
    Laev.Dictionary.init()
    Laev.SubtitleCache.init()
    Laev.Resume.init()
    Laev.Watchlist.init()

    children = [
      {Registry, keys: :unique, name: Laev.Remux.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Laev.Remux.Supervisor}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Laev.Supervisor)

    # As a Burrito-wrapped release (the standalone binary), booting the app IS
    # the CLI invocation — run it and halt before `elixir start_cli` gets a
    # chance to misread our arguments as a script path. As an escript,
    # escript's main/1 drives instead.
    if Burrito.Util.running_standalone?() do
      Laev.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    end

    result
  end

  # One-time rename migration: adopt the old ~/.config/{kala,kino}/config and
  # ~/.{kala,kino} data dirs (positions, tracks, resume, watchlist, blocklist)
  # when the new laev locations don't exist yet — the most recent old name
  # wins. Best-effort — never blocks boot.
  defp migrate_from_old_names do
    home = System.user_home!()
    config_home = System.get_env("XDG_CONFIG_HOME") || Path.join(home, ".config")

    for old <- ["kala", "kino"] do
      migrate_dir(Path.join(config_home, old), Path.join(config_home, "laev"))
      migrate_dir(Path.join(home, "." <> old), Path.join(home, ".laev"))
    end

    :ok
  rescue
    _ -> :ok
  end

  defp migrate_dir(old, new) do
    if File.dir?(old) and not File.exists?(new) do
      File.cp_r(old, new)

      # Old-name banner art would keep overriding the new built-in wordmark —
      # don't carry it across the rename.
      Path.join(new, "banner*.txt") |> Path.wildcard() |> Enum.each(&File.rm/1)
    end
  end
end
