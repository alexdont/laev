defmodule Laev.SyncServerTest do
  use ExUnit.Case, async: true

  alias Laev.SyncServer, as: Server

  describe "the key is the credential" do
    test "a well-formed key is its own tenant — no guest list" do
      assert Server.token_ok?("laev_" <> String.duplicate("a", 40))
      assert Server.token_ok?("laev_" <> String.duplicate("a", 30))
    end

    test "anything else is refused" do
      refute Server.token_ok?("laev_tooshort")
      refute Server.token_ok?("notlaev_" <> String.duplicate("a", 40))
      refute Server.token_ok?("laev_" <> String.duplicate("a", 100))
      refute Server.token_ok?(nil)
      refute Server.token_ok?("laev_has spaces in it and is long enough yes")
    end

    test "only the hash of a key is worth storing" do
      key = "laev_" <> String.duplicate("a", 40)

      assert Server.token_hash(key) =~ ~r/^[0-9a-f]{64}$/
      refute Server.token_hash(key) =~ "laev_"
    end
  end

  describe "what counts as a laev document" do
    test "anything carrying a known key is one" do
      assert Server.plausible?(~s({"version":1}))
      assert Server.plausible?(~s({"watchlist":{}}))
      assert Server.plausible?(~s({"positions":{},"somethingnew":{}}))
    end

    test "junk is not" do
      refute Server.plausible?(~s({"hello":"world"}))
      refute Server.plausible?("not json at all")
      refute Server.plausible?(~s([1,2,3]))
      refute Server.plausible?("")
    end
  end

  describe "ETags" do
    # The contract is byte-for-byte fidelity, so the tag has to come from the
    # bytes — a re-encoding of the same data is a different document.
    test "identical bytes give an identical tag" do
      body = ~s({"version":1,"watchlist":{}})
      assert Server.etag(body) == Server.etag(body)
    end

    test "non-canonical JSON is not the same document" do
      a = ~s({"version":1,"watchlist":{}})
      b = ~s({ "watchlist" : {} , "version" : 1 })

      assert Jason.decode!(a) == Jason.decode!(b), "the same data"
      refute Server.etag(a) == Server.etag(b), "and not the same bytes"
    end

    test "an If-Match header is read whether quoted or weak" do
      assert Server.parse_if_match(~s("abc")) == "abc"
      assert Server.parse_if_match(~s(W/"abc")) == "abc"
      assert Server.parse_if_match(["\"abc\""]) == "abc"
      assert Server.parse_if_match([]) == nil
    end
  end

  describe "merging a partial bundle" do
    test "the newer record wins, and a tie goes to the incoming one" do
      stored = %{"watchlist" => %{"tv:1" => %{"data" => %{"t" => "old"}, "updated_at" => 100}}}

      newer = %{"watchlist" => %{"tv:1" => %{"data" => %{"t" => "new"}, "updated_at" => 200}}}
      assert {:ok, merged} = Server.merge(stored, newer)
      assert merged["watchlist"]["tv:1"]["data"]["t"] == "new"

      older = %{"watchlist" => %{"tv:1" => %{"data" => %{"t" => "older"}, "updated_at" => 50}}}
      assert {:ok, kept} = Server.merge(stored, older)
      assert kept["watchlist"]["tv:1"]["data"]["t"] == "old"

      tie = %{"watchlist" => %{"tv:1" => %{"data" => %{"t" => "tie"}, "updated_at" => 100}}}
      assert {:ok, tied} = Server.merge(stored, tie)
      assert tied["watchlist"]["tv:1"]["data"]["t"] == "tie"
    end

    # Dropping a tombstone is how an unpinned title comes back on the next sync.
    test "a tombstone is stored, not discarded" do
      stored = %{"watchlist" => %{"tv:1" => %{"data" => %{}, "updated_at" => 100}}}
      patch = %{"watchlist" => %{"tv:1" => %{"data" => %{}, "updated_at" => 200, "deleted" => true}}}

      assert {:ok, merged} = Server.merge(stored, patch)
      assert merged["watchlist"]["tv:1"]["deleted"] == true
    end

    test "what the patch does not mention is untouched" do
      stored = %{
        "watchlist" => %{"tv:1" => %{"updated_at" => 100}},
        "positions" => %{"movie-9" => %{"updated_at" => 100}}
      }

      assert {:ok, merged} = Server.merge(stored, %{"watchlist" => %{"tv:2" => %{"updated_at" => 1}}})
      assert Map.keys(merged["watchlist"]) |> Enum.sort() == ["tv:1", "tv:2"]
      assert merged["positions"] == stored["positions"]
    end

    # A newer client gained holds, anime and seasons after the server was
    # written; one that rejected them would have broken every new client.
    test "a collection this server has never heard of is carried anyway" do
      assert {:ok, merged} = Server.merge(%{}, %{"holds" => %{"tv:1" => %{"updated_at" => 1}}})
      assert merged["holds"]["tv:1"]
    end

    test "version only goes up" do
      assert {:ok, %{"version" => 2}} = Server.merge(%{"version" => 2}, %{"version" => 1})
      assert {:ok, %{"version" => 3}} = Server.merge(%{"version" => 2}, %{"version" => 3})
    end

    test "a collection that is not a map of records is refused" do
      assert Server.merge(%{}, %{"watchlist" => "nonsense"}) == {:error, :invalid}
      assert Server.merge(%{}, %{"positions" => [1, 2]}) == {:error, :invalid}
    end

    test "a document stored oddly through PUT is replaced rather than crashed on" do
      assert {:ok, merged} =
               Server.merge(%{"watchlist" => "junk"}, %{"watchlist" => %{"tv:1" => %{"updated_at" => 1}}})

      assert merged["watchlist"]["tv:1"]
    end

    test "the same merge over JSON text" do
      stored = ~s({"version":1,"watchlist":{"tv:1":{"updated_at":100}}})
      patch = ~s({"watchlist":{"tv:1":{"updated_at":200,"data":{"t":"new"}}}})

      assert {:ok, body} = Server.merge_json(stored, patch)
      assert Jason.decode!(body)["watchlist"]["tv:1"]["data"]["t"] == "new"
    end

    test "a patch that is not an object is refused" do
      assert Server.merge_json(~s({}), "nope") == {:error, :invalid}
    end
  end

  test "the size limit is the documented one" do
    assert Server.max_bytes() == 5 * 1024 * 1024
  end
end
