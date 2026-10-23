defmodule Laev.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # First, before anything has the chance to log: nothing may write to the
    # terminal laev is about to draw on.
    Laev.Log.install()

    migrate_from_old_names()
    migrate_hosted_sync_url()
    Laev.Config.load()
    Laev.Blocklist.init()
    Laev.Dictionary.init()
    Laev.SubtitleCache.init()
    Laev.Resume.init()
    Laev.Watchlist.init()
    # In the background: the answer is wanted by the time the menu draws, and
    # nothing should wait on it to get there.
    Laev.Account.warm()

    children = [
      {Registry, keys: :unique, name: Laev.Remux.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Laev.Remux.Supervisor}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Laev.Supervisor)

    # As a Burrito-wrapped release (the standalone binary), booting the app IS
    # the CLI invocation — run it and halt before `elixir start_cli` gets a
    # chance to misread our arguments as a script path. As an escript,
    # escript's main/1 drives instead.
    if standalone?() do
      Laev.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    end

    result
  end

  # Whether this is the standalone binary rather than a library inside
  # somebody else's app. Asked carefully: burrito is optional for anyone
  # depending on laev, so on a web server the module is simply not there.
  defp standalone? do
    Code.ensure_loaded?(Burrito.Util) and
      function_exported?(Burrito.Util, :running_standalone?, 0) and
      Burrito.Util.running_standalone?()
  end

  # The hosted sync store moved from sasha.don.ee/laev to roki.ee/api/laev.
  #
  # The old address still forwards, so an install that saved it keeps working
  # and nothing here is urgent — but a saved copy of it means depending on that
  # forward forever, so exactly that one value is rewritten. Exactly: anything
  # else is somebody's own server, and rewriting that would point them at a
  # stranger's. Only touched when it is in the config file, never when it comes
  # from the environment, which is not ours to edit.
  @doc false
  def migrate_hosted_sync_url do
    if Laev.Config.file_value("LAEV_SYNC_URL") == Laev.Sync.legacy_url() do
      Laev.Config.write([{"LAEV_SYNC_URL", Laev.Sync.default_url()}])
      Laev.Scope.set(:sync_url, Laev.Sync.default_url())
    end

    :ok
  rescue
    _ -> :ok
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
