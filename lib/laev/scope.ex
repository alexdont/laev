defmodule Laev.Scope do
  @moduledoc """
  Whose laev this is.

  Everything laev knows — your keys, your marks, your watchlist — used to be
  global: one data directory, one Real-Debrid token, one named ETS table, all
  read straight out of the application environment. That is exactly right for a
  command somebody runs on their own machine, and exactly wrong for a server
  where two people are logged in at once, where it would mean one account's
  token fetching another account's film.

  A scope is a user's half of that: a directory to keep their state in, and the
  keys to the services they have connected. It is bound to the *process* rather
  than passed through every function, because the alternative is a parameter on
  several hundred signatures, and because the BEAM already gives us the
  isolation for free — Phoenix runs each request and each LiveView in its own
  process, so binding there is the same thing as binding per user.

  Nothing is bound by default, and everything falls back to the application
  environment, so the CLI goes on behaving exactly as it did: one person, one
  machine, no scope at all.

  The one place this leaks is work handed to another process, which does not
  inherit a process dictionary. `async_stream/3`, `async/1` and `spawn/1` here
  carry the scope across for you; `Task.async` and `spawn` directly do not,
  which is the single rule to remember when adding work that runs elsewhere.
  """

  @key {__MODULE__, :current}

  defstruct [:dir, config: %{}]

  @type t :: %__MODULE__{dir: String.t(), config: map()}

  @doc """
  A scope over a directory, with the keys that belong to whoever owns it.

  `config` holds the same names the config file uses — `:rd_token`,
  `:tmdb_key`, `:torbox_api_key` and the rest — and anything absent from it
  falls back to the application environment, so a server can share, say, one
  TMDB key across everybody while each person brings their own debrid account.
  """
  def new(dir, config \\ %{}) when is_binary(dir) and is_map(config) do
    %__MODULE__{dir: dir, config: config}
  end

  @doc """
  A scope over a directory, with whatever that user has already saved in it.

  How a request should build one: the settings a user changed last time are in
  their own directory, and anything the server holds for them — a token kept in
  a database rather than on disk, say — is passed in and wins.
  """
  def load(dir, overrides \\ %{}) when is_binary(dir) do
    File.mkdir_p(dir)
    new(dir, Map.merge(Laev.Config.read_dir(dir), overrides))
  end

  @doc "The scope bound to this process, or nil when there isn't one."
  def current, do: Process.get(@key)

  @doc """
  Run `fun` with `scope` bound, restoring whatever was bound before.

  The way a web request should enter laev: bind once at the edge, and every
  call underneath is that user's without being told so.
  """
  def run(%__MODULE__{} = scope, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, scope)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "Bind a scope to this process for good — for a LiveView's mount."
  def put(%__MODULE__{} = scope), do: Process.put(@key, scope)

  @doc "Unbind."
  def clear, do: Process.delete(@key)

  @overrides {__MODULE__, :overrides}

  @doc """
  Run `fun` with some settings replaced, without changing what anyone has saved.

  For one title in languages chosen for it — a film watched in French by
  somebody learning French, whose own settings still say English. The overrides
  sit on top of the scope's own values and come off afterwards, so nothing
  leaks into the next thing that process does.

  Carried into `async/1`, `async_stream/3` and `spawn/1` the way the scope
  itself is, which is the point: the work that fetches sources and starts a
  player happens in other processes, and an override that did not follow it
  would apply to the page and not to the playback.
  """
  def with_overrides(overrides, fun) when is_map(overrides) and is_function(fun, 0) do
    previous = Process.get(@overrides)
    Process.put(@overrides, Map.merge(previous || %{}, overrides))

    try do
      fun.()
    after
      if previous, do: Process.put(@overrides, previous), else: Process.delete(@overrides)
    end
  end

  @doc "The settings currently overridden for this process."
  def overrides, do: Process.get(@overrides) || %{}

  @doc "Bind overrides for good — for a LiveView that stays in one mode."
  def put_overrides(overrides) when is_map(overrides), do: Process.put(@overrides, overrides)

  @doc "Drop any overrides."
  def clear_overrides, do: Process.delete(@overrides)

  # ── what every module asks ────────────────────────────────────────

  @doc """
  A setting, for whoever this process belongs to.

  The scope's own value where it has one, the application environment
  otherwise — which is every value when nothing is bound, and is why the CLI
  does not know this module exists.
  """
  def get(key, default \\ nil) do
    case Map.fetch(overrides(), key) do
      {:ok, value} -> value
      :error -> from_scope(key, default)
    end
  end

  defp from_scope(key, default) do
    case current() do
      %__MODULE__{config: config} ->
        case Map.fetch(config, key) do
          {:ok, value} -> value
          :error -> fallback(key, default)
        end

      _ ->
        Application.get_env(:laev, key, default)
    end
  end

  # Which account this is cannot be inherited.
  #
  # Falling back to the application environment is right for a key a server
  # might reasonably share — one TMDB key for everybody is a normal thing to
  # want — and wrong for the laev key, which does not grant access to a
  # service but names a *person's* document. A user who had never connected
  # one was reading the machine owner's: their watchlist, their marks, and a
  # sync away from writing to them.
  @never_inherited [:sync_token]

  defp fallback(key, default) when key in @never_inherited, do: default
  defp fallback(key, default), do: Application.get_env(:laev, key, default)

  @doc """
  Change a setting for whoever this process belongs to.

  Within a scope it changes that scope and nothing else — one user turning on
  VLC is not every user turning on VLC. Unscoped it is the application
  environment, which is what makes the Settings screen apply immediately.
  """
  def set(key, value) do
    case current() do
      %__MODULE__{config: config} = scope ->
        put(%{scope | config: Map.put(config, key, value)})
        :ok

      _ ->
        Application.put_env(:laev, key, value)
    end
  end

  @doc "Where this user's state lives."
  def dir do
    case current() do
      %__MODULE__{dir: dir} when is_binary(dir) -> dir
      _ -> Application.get_env(:laev, :data_dir) || Path.join(System.user_home!(), ".laev")
    end
  end

  @doc """
  A name unique to this scope, for the things that must not be shared by name —
  the ETS tables holding the watchlist and the history.
  """
  def tag do
    case current() do
      %__MODULE__{dir: dir} -> "u" <> (:erlang.phash2(dir) |> Integer.to_string(36))
      _ -> "global"
    end
  end

  # ── carrying it to work that happens elsewhere ────────────────────

  @doc "Task.async_stream, with this process's scope bound inside each task."
  def async_stream(enumerable, fun, opts \\ []) do
    scope = current()
    overrides = overrides()
    Task.async_stream(enumerable, fn item -> with_scope(scope, overrides, fn -> fun.(item) end) end, opts)
  end

  @doc "Task.async, with the scope carried across."
  def async(fun) do
    scope = current()
    overrides = overrides()
    Task.async(fn -> with_scope(scope, overrides, fun) end)
  end

  @doc "spawn, with the scope carried across."
  def spawn(fun) do
    scope = current()
    overrides = overrides()
    Kernel.spawn(fn -> with_scope(scope, overrides, fun) end)
  end

  defp with_scope(scope, overrides, fun) do
    bound = if overrides == %{}, do: fun, else: fn -> with_overrides(overrides, fun) end

    case scope do
      nil -> bound.()
      %__MODULE__{} -> run(scope, bound)
    end
  end
end
