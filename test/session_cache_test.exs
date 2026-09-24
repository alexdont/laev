defmodule Laev.SessionCacheTest do
  use ExUnit.Case, async: true

  alias Laev.SessionCache

  setup do
    # The process dictionary is per-test-process, so each test starts clean.
    {:ok, key: {:season_count, 12_345, 1}}
  end

  test "a fresh value is served without asking again", %{key: key} do
    assert SessionCache.fetch(key, 60, fn -> 7 end) == 7
    assert SessionCache.fetch(key, 60, fn -> flunk("should not have been called") end) == 7
  end

  test "a value past its age is fetched again", %{key: key} do
    assert SessionCache.fetch(key, 60, fn -> 7 end) == 7
    age(key, 61)

    # The show aired another episode while the session sat open.
    assert SessionCache.fetch(key, 60, fn -> 8 end) == 8
  end

  test "a value exactly at its age is still good", %{key: key} do
    assert SessionCache.fetch(key, 60, fn -> 7 end) == 7
    age(key, 60)

    assert SessionCache.fetch(key, 60, fn -> 8 end) == 7
  end

  test "nothing is never remembered", %{key: key} do
    assert SessionCache.fetch(key, 60, fn -> nil end) == nil
    assert SessionCache.peek(key) == :miss

    # The point: the next ask gets the episode that has since aired.
    assert SessionCache.fetch(key, 60, fn -> 8 end) == 8
  end

  test "forget sends the next ask back to the source", %{key: key} do
    assert SessionCache.fetch(key, 60, fn -> 7 end) == 7
    SessionCache.forget(key)

    assert SessionCache.fetch(key, 60, fn -> 8 end) == 8
  end

  test "keys don't collide with anything else in the process", %{key: key} do
    Process.put(key, :something_else)
    assert SessionCache.fetch(key, 60, fn -> 7 end) == 7

    assert Process.get(key) == :something_else
  end

  test "put and get are the same store, with the same clock", %{key: key} do
    assert SessionCache.put(key, 7) == 7
    assert SessionCache.get(key, 60) == 7
    age(key, 61)

    assert SessionCache.get(key, 60) == nil
  end

  # Backdate an entry by rewriting its timestamp.
  defp age(key, seconds) do
    {value, at} = Process.get({SessionCache, key})
    Process.put({SessionCache, key}, {value, at - seconds})
  end
end
