defmodule Laev.ScopeTest do
  use ExUnit.Case, async: false

  alias Laev.{Position, Resume, Scope, Watchlist}

  setup do
    base = Path.join(System.tmp_dir!(), "laev-scope-#{System.unique_integer([:positive])}")
    alice = Scope.new(Path.join(base, "alice"), %{rd_token: "alice-token", lang: "en"})
    bob = Scope.new(Path.join(base, "bob"), %{rd_token: "bob-token", lang: "ru"})
    for s <- [alice, bob], do: File.mkdir_p!(Path.join(s.dir, "positions"))
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, alice: alice, bob: bob, base: base}
  end

  # The thing a server cannot get wrong: one account's token fetching another
  # account's film.
  test "two users have their own keys", %{alice: alice, bob: bob} do
    assert Scope.run(alice, fn -> Scope.get(:rd_token) end) == "alice-token"
    assert Scope.run(bob, fn -> Scope.get(:rd_token) end) == "bob-token"
  end

  # Anything the scope doesn't carry falls back to what the server holds, so a
  # shared TMDB key can be shared while debrid accounts are not.
  test "what a scope doesn't carry falls back", %{alice: alice} do
    Application.put_env(:laev, :shared_thing, "server-wide")
    on_exit(fn -> Application.delete_env(:laev, :shared_thing) end)

    assert Scope.run(alice, fn -> Scope.get(:shared_thing) end) == "server-wide"
    assert Scope.run(alice, fn -> Scope.get(:rd_token) end) == "alice-token"
  end

  test "marks land in their own user's directory", %{alice: alice, bob: bob} do
    Scope.run(alice, fn -> Position.set_watched(%{type: "movie", tmdb_id: 603}, true) end)

    assert Scope.run(alice, fn -> Position.finished?(%{type: "movie", tmdb_id: 603}) end)
    refute Scope.run(bob, fn -> Position.finished?(%{type: "movie", tmdb_id: 603}) end)
    assert File.exists?(Path.join([alice.dir, "positions", "movie-603"]))
    refute File.exists?(Path.join([bob.dir, "positions", "movie-603"]))
  end

  # The watchlist and history live in named ETS tables, which are shared by
  # every process in the VM unless the name is the scope's.
  test "the in-memory tables are not shared either", %{alice: alice, bob: bob} do
    film = %{type: "movie", id: 603, title: "The Matrix", year: "1999", poster: nil}

    Scope.run(alice, fn -> Watchlist.add(film) end)

    assert Scope.run(alice, fn -> Watchlist.has?("movie", 603) end)
    refute Scope.run(bob, fn -> Watchlist.has?("movie", 603) end)
    assert Scope.run(alice, fn -> Watchlist.count() end) == 1
    assert Scope.run(bob, fn -> Watchlist.count() end) == 0
  end

  test "history is per user too", %{alice: alice, bob: bob} do
    Scope.run(alice, fn -> Resume.put("movie", 603, %{"type" => "movie", "tmdb_id" => 603, "title" => "The Matrix"}) end)

    assert Scope.run(alice, fn -> Resume.get("movie", 603) end)
    refute Scope.run(bob, fn -> Resume.get("movie", 603) end)
  end

  # Work handed to another process does not inherit a process dictionary, and a
  # task that lost its scope would write into whoever's directory was default.
  test "work done in other processes stays in the right account", %{alice: alice, bob: bob} do
    seen =
      Scope.run(alice, fn ->
        Scope.async_stream([1, 2, 3], fn _ -> Scope.get(:rd_token) end, max_concurrency: 3)
        |> Enum.map(fn {:ok, token} -> token end)
      end)

    assert seen == ["alice-token", "alice-token", "alice-token"]

    task = Scope.run(bob, fn -> Scope.async(fn -> Scope.dir() end) end)
    assert Task.await(task) == bob.dir
  end

  # Two users at once, which is the whole point.
  test "concurrent users do not bleed into each other", %{alice: alice, bob: bob} do
    [a, b] =
      [{alice, 1}, {bob, 2}]
      |> Enum.map(fn {scope, id} ->
        Task.async(fn ->
          Scope.run(scope, fn ->
            Position.set_watched(%{type: "movie", tmdb_id: id}, true)
            Process.sleep(20)
            {Scope.get(:rd_token), Position.finished?(%{type: "movie", tmdb_id: id})}
          end)
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert a == {"alice-token", true}
    assert b == {"bob-token", true}
    refute Scope.run(alice, fn -> Position.finished?(%{type: "movie", tmdb_id: 2}) end)
  end

  # The caches are process-local, and a process is not always one person: a
  # server looping over accounts would otherwise hand the second one the
  # first one's answers. It did, the first time this was tried.
  test "what one user's answers were cached as is not served to the next", %{alice: alice, bob: bob} do
    Scope.run(alice, fn ->
      Laev.SessionCache.put(:who, "alice")
      assert Laev.SessionCache.get(:who, 60) == "alice"
    end)

    Scope.run(bob, fn ->
      refute Laev.SessionCache.get(:who, 60), "bob must not see alice's answer"
      Laev.SessionCache.put(:who, "bob")
    end)

    assert Scope.run(alice, fn -> Laev.SessionCache.get(:who, 60) end) == "alice"
    assert Scope.run(bob, fn -> Laev.SessionCache.get(:who, 60) end) == "bob"
  end

  # Falling back to the server's own configuration is right for a key a server
  # might share — one TMDB key for everybody is a normal thing to want — and
  # wrong for the laev key, which names a person's document rather than
  # granting access to a service. A user who had never connected one was
  # reading the machine owner's watchlist, and a sync away from writing to it.
  test "which account this is cannot be inherited", %{alice: alice} do
    # Put back what was there, rather than deleting: wiping the real TMDB key
    # for the rest of the run broke nine unrelated tests the first time.
    previous = for k <- [:sync_token, :tmdb_key], do: {k, Application.get_env(:laev, k)}
    Application.put_env(:laev, :sync_token, "laev_theoperatorskey.secret")
    Application.put_env(:laev, :tmdb_key, "a-shared-server-key")

    on_exit(fn ->
      for {k, v} <- previous do
        if v, do: Application.put_env(:laev, k, v), else: Application.delete_env(:laev, k)
      end
    end)

    Scope.run(alice, fn ->
      refute Scope.get(:sync_token), "a user who never connected has no key, not the server's"
      assert Scope.get(:tmdb_key) == "a-shared-server-key", "a shared key is still shared"
    end)

    # Unscoped — the terminal — reads its own as it always has.
    assert Scope.get(:sync_token) == "laev_theoperatorskey.secret"
  end

  # And the CLI, which binds nothing, must behave exactly as it always did.
  test "no scope means the machine's own laev" do
    assert Scope.current() == nil
    assert Scope.dir() == Application.get_env(:laev, :data_dir) || Path.join(System.user_home!(), ".laev")
    assert Scope.tag() == "global"
  end
end
