defmodule Laev.SyncConnectTest do
  use ExUnit.Case, async: false

  alias Laev.{Scope, Sync}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-connect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{})}
  end

  # A sync setting that silently does nothing is worse than an error: the first
  # anyone would know of it is a watchlist that stopped following them.
  test "a key that is not a key is refused before anything is saved", %{scope: scope} do
    Scope.run(scope, fn ->
      assert {:error, {:bad_key, _}} = Sync.connect("nonsense")
      assert {:error, {:bad_key, _}} = Sync.connect("laev_x")
      refute Sync.enabled?(), "nothing was configured by a refused key"
    end)
  end

  test "a server that is not a URL is refused too", %{scope: scope} do
    Scope.run(scope, fn ->
      assert {:error, {:bad_url, _}} = Sync.connect("laev_" <> String.duplicate("a", 32), "not a url")
      refute Sync.enabled?()
    end)
  end

  # "Configured" has to mean "could actually sync", or a settings page will
  # report a connection that cannot carry anything.
  test "a server without a key is not a connection", %{scope: scope} do
    with_url = Scope.new(scope.dir, %{sync_url: "https://example.test/laev"})

    Scope.run(with_url, fn ->
      refute Sync.enabled?()
      assert Sync.check() == {:error, :not_configured}
    end)
  end

  test "nothing configured says so rather than failing obscurely", %{scope: scope} do
    Scope.run(scope, fn -> assert Sync.check() == {:error, :not_configured} end)
  end
end
