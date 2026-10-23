defmodule Laev.HostedSyncUrlTest do
  use ExUnit.Case, async: false

  alias Laev.{Config, Scope, Sync}

  test "the hosted address is roki, and there is one copy of it" do
    assert Sync.default_url() == "https://roki.ee/api/laev"

    # The CLI used to keep its own literal. Both must now say the same thing,
    # whatever it is, because the address has moved once already.
    assert Sync.default_url() == hosted_offered_by_the_cli()
  end

  # The old address still forwards and must keep working: an install that saved
  # it is not broken, it is just pointing at the long way round.
  test "the old address is still recognised as the hosted one" do
    assert Sync.legacy_url() == "https://sasha.don.ee/laev"
    refute Sync.legacy_url() == Sync.default_url()
  end

  describe "the one-time rewrite of a saved address" do
    setup do
      dir = Path.join(System.tmp_dir!(), "laev-url-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, scope: Scope.new(dir, %{})}
    end

    test "a saved copy of the old hosted address is brought forward", %{scope: scope} do
      Scope.run(scope, fn ->
        Config.write([{"LAEV_SYNC_URL", Sync.legacy_url()}])
        assert Config.file_value("LAEV_SYNC_URL") == Sync.legacy_url()

        Laev.Application.migrate_hosted_sync_url()

        assert Config.file_value("LAEV_SYNC_URL") == Sync.default_url()
      end)
    end

    # The important half: anything else is somebody's own server, and rewriting
    # that would point them at a stranger's.
    test "a server somebody runs themselves is left alone", %{scope: scope} do
      Scope.run(scope, fn ->
        Config.write([{"LAEV_SYNC_URL", "https://sync.my-own-box.example/laev"}])

        Laev.Application.migrate_hosted_sync_url()

        assert Config.file_value("LAEV_SYNC_URL") == "https://sync.my-own-box.example/laev"
      end)
    end

    test "nothing saved stays nothing saved", %{scope: scope} do
      Scope.run(scope, fn ->
        Laev.Application.migrate_hosted_sync_url()

        refute Config.file_value("LAEV_SYNC_URL")
      end)
    end
  end

  # Read off the source, because the thing being guarded against is a second
  # literal drifting from the first — and a helper that returns default_url/0
  # would assert that default_url/0 equals itself, which was the first version
  # of this test.
  defp hosted_offered_by_the_cli do
    source = File.read!("lib/laev/cli.ex")

    hosts = [URI.parse(Sync.default_url()).host, URI.parse(Sync.legacy_url()).host]

    case Enum.filter(hosts, &String.contains?(source, &1)) do
      [] -> Sync.default_url()
      found -> {:cli_hardcodes_a_sync_host, found}
    end
  end
end
