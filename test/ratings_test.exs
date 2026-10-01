defmodule Laev.RatingsTest do
  use ExUnit.Case, async: true

  alias Laev.Ratings

  # The import writes watched marks on someone's behalf across a whole library,
  # so the only question that matters is when it must NOT write.
  test "a title laev knows nothing about gets marked" do
    assert Ratings.decide(:none) == :mark
  end

  test "a title already watched is left as it is, and counted separately" do
    # So a second import reports "already were" instead of claiming new marks.
    assert Ratings.decide(:watched) == :already
  end

  test "a part-watched position is never stamped over" do
    # Somebody's place in something they're halfway through, against a rating
    # that may predate the rewatch. The position wins; the import says so.
    assert Ratings.decide({:partial, 1420}) == :partial
    assert Ratings.decide({:partial, 1}) == :partial
  end
end
