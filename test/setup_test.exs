defmodule Laev.SetupTest do
  use ExUnit.Case, async: false

  alias Laev.{Config, Scope, Setup}

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, scope: Scope.new(dir, %{})}
  end

  # A half-configured laev looks ready and then cannot play anything, and the
  # reason is in a config file rather than on screen.
  test "nothing can be found without TMDB", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Setup.first_run(%{"RD_TOKEN" => "x"}) == {:error, :tmdb_key_required}
      refute Config.file_value("RD_TOKEN")
    end)
  end

  test "nothing can be played without a debrid provider", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Setup.first_run(%{"TMDB_API_KEY" => "x"}) == {:error, :debrid_key_required}
      refute Config.file_value("TMDB_API_KEY")
    end)
  end

  test "blanks don't count as given", %{scope: scope} do
    Scope.run(scope, fn ->
      assert Setup.first_run(%{"TMDB_API_KEY" => "  ", "RD_TOKEN" => "x"}) ==
               {:error, :tmdb_key_required}
    end)
  end

  # Each key is checked against its own service, so a typo is an error at setup
  # rather than a failure at the first film.
  test "a key the service rejects fails setup and saves nothing", %{scope: scope} do
    Scope.run(scope, fn ->
      # Which of the two is reported depends on map order, which is not a
      # contract; that one of them is, and that nothing was saved, is.
      assert {:error, {rejected, _why}} =
               Setup.first_run(%{"TMDB_API_KEY" => "not-a-real-key", "RD_TOKEN" => "nor-is-this"})

      assert rejected in ["TMDB_API_KEY", "RD_TOKEN"]

      refute Config.file_value("TMDB_API_KEY")
      refute Config.file_value("LAEV_SYNC_TOKEN")
    end)
  end

  describe "the laev key it makes" do
    test "is the shape the sync server accepts" do
      key = Setup.generate_key()

      assert String.starts_with?(key, "laev_")
      assert [token, secret] = String.split(key, ".")
      assert Regex.match?(~r/^laev_[A-Za-z0-9_-]{30,64}$/, token), "the half the server sees"
      assert byte_size(secret) >= 30, "the half that never leaves the machine"
    end

    test "is different every time" do
      assert Setup.generate_key() != Setup.generate_key()
    end
  end

  describe "replace_key" do
    test "a rejected key never becomes the configured one", %{scope: scope} do
      Scope.run(scope, fn ->
        assert {:error, _} = Setup.replace_key("TMDB_API_KEY", "not-a-real-key")
        refute Config.file_value("TMDB_API_KEY")
      end)
    end

    test "an empty one is refused before anything is asked", %{scope: scope} do
      Scope.run(scope, fn -> assert Setup.replace_key("TMDB_API_KEY", "  ") == {:error, :empty} end)
    end
  end
end
