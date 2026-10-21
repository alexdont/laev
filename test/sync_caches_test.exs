defmodule Laev.SyncCachesTest do
  use ExUnit.Case, async: false

  # The shelves are counted from more than marks: which anime you put on hold
  # lives in anime.json, how many seasons have aired in seasons.json. A device
  # without them cannot tell "on hold" from "in the middle of", so it counts
  # everything as behind — the same account read 27 on one machine and 69 on
  # another. Both are facts about the account, so both travel.
  test "the caches the counts depend on are synced" do
    collections = Laev.Sync.collections()

    assert :anime in collections, "which anime you have put down follows you"
    assert :seasons in collections, "how much of a show exists follows you"
  end

  # And they travel as caches, not as decisions. Unpinning a title is something
  # you did and must propagate; not having a cache file is something you
  # haven't done, and tombstoning it would let the emptiest machine erase the
  # list for every other one.
  test "a cache absent on one device is not a deletion everywhere" do
    now = 1_700_000_000
    known = %{"data" => %{"status" => "on_hold"}, "updated_at" => now - 100, "deleted" => false}

    assert Laev.Sync.reconcile(:anime, "62601", nil, known, now) == known,
           "gone locally keeps what is known"

    assert %{"deleted" => true} = Laev.Sync.reconcile(:watchlist, "movie:1", nil, known, now),
           "an unpinned title is still a real deletion"
  end

  test "having a cache again outranks an old tombstone" do
    now = 1_700_000_000
    tombstone = %{"data" => %{"status" => "watching"}, "updated_at" => now - 100, "deleted" => true}
    mine = %{"status" => "on_hold"}

    assert %{"data" => ^mine, "deleted" => false} = Laev.Sync.reconcile(:anime, "62601", mine, tombstone, now)
  end
end
