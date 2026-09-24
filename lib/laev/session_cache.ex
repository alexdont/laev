defmodule Laev.SessionCache do
  @moduledoc """
  What laev remembers for the length of one run, and for how long.

  Answers from TMDB about a show that is still airing are true when asked and
  wrong later: a session left open for a week is still holding last week's
  idea of how many episodes exist. Everything here therefore carries an age,
  and goes back to the source once it is past it.

  Two rules, both learned from the same bug:

    * **Nothing is remembered.** A lookup that came back empty — no count, no
      next episode — is exactly the answer that changes when an episode drops,
      so it is never cached. Asking again costs one request; being wrong costs
      the user the episode they sat down to watch.
    * **Identity is not news.** Things that cannot change (a title's MyAnimeList
      id) don't belong here; cache those outright.

  Per-process, like the process dictionary it is built on: each laev run has
  its own, and nothing survives the exit.
  """

  @doc """
  The cached value for `key`, or `fun.()` when there is none or it has aged
  past `ttl_s` seconds. `nil` results are returned but never stored.
  """
  def fetch(key, ttl_s, fun) when is_integer(ttl_s) and is_function(fun, 0) do
    case get(key, ttl_s) do
      nil ->
        case fun.() do
          nil -> nil
          value -> put(key, value)
        end

      value ->
        value
    end
  end

  @doc "The cached value for `key` if it is younger than `ttl_s`, else nil."
  def get(key, ttl_s) when is_integer(ttl_s) do
    now = System.os_time(:second)

    case Process.get({__MODULE__, key}, :miss) do
      {value, at} when now - at <= ttl_s -> value
      _ -> nil
    end
  end

  @doc "Remember `value` under `key`, starting its clock now. Returns it."
  def put(key, value) do
    Process.put({__MODULE__, key}, {value, System.os_time(:second)})
    value
  end

  @doc "Drop a key, so the next `fetch/3` goes back to the source."
  def forget(key), do: Process.delete({__MODULE__, key})

  @doc false
  # Tests and anything that needs to know whether a value is being held.
  def peek(key) do
    case Process.get({__MODULE__, key}, :miss) do
      {value, _at} -> {:ok, value}
      _ -> :miss
    end
  end
end
