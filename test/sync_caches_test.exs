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

  describe "a device that was never told" do
    # Asking MyAnimeList about an anime that isn't on your list answers with no
    # status at all. Such a record used to win on a timestamp and overwrite the
    # real one: twenty-one anime came back from "on hold" to "watching" after a
    # sync with a machine that had never been told they were put down.
    test "knowing a status beats not knowing one, whatever the clock says" do
      now = 1_700_000_000
      knows = %{"data" => %{"status" => "on_hold"}, "updated_at" => now - 10_000, "deleted" => false}
      blank = %{"data" => %{"status" => nil, "title" => "Nana"}, "updated_at" => now, "deleted" => false}

      assert Laev.Sync.pick_record(:anime, blank, knows) == knows, "the newer empty one must lose"
      assert Laev.Sync.pick_record(:anime, knows, blank) == knows
    end

    test "between two that both know, the newer one still wins" do
      now = 1_700_000_000
      older = %{"data" => %{"status" => "watching"}, "updated_at" => now - 10_000, "deleted" => false}
      newer = %{"data" => %{"status" => "on_hold"}, "updated_at" => now, "deleted" => false}

      assert Laev.Sync.pick_record(:anime, older, newer) == newer
      assert Laev.Sync.pick_record(:anime, newer, older) == newer
    end

    # A record laev looked up rather than one MyAnimeList described knows
    # nothing about when it was true, so it must not start at this moment.
    test "a record with no timestamp of its own starts at the beginning" do
      now = 1_700_000_000

      assert %{"updated_at" => 0} =
               Laev.Sync.reconcile(:anime, "877", %{"title" => "Nana", "status" => nil}, nil, now)

      assert %{"updated_at" => 1_600_000_000} =
               Laev.Sync.reconcile(:anime, "877", %{"status" => "on_hold", "updated" => 1_600_000_000}, nil, now)
    end
  end
end
