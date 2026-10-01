defmodule Laev.MalProgressTest do
  use ExUnit.Case, async: true

  alias Laev.MAL

  test "the last episode completes the anime and dates it" do
    fields = MAL.progress_fields(12, 12)

    assert fields.status == "completed"
    assert fields.num_episodes_watched == 12
    assert fields.finish_date == Date.to_iso8601(Date.utc_today())
  end

  test "one episode short is still watching, with no finish date" do
    fields = MAL.progress_fields(11, 12)

    assert fields.status == "watching"
    assert fields.num_episodes_watched == 11
    refute Map.has_key?(fields, :finish_date)
  end

  # A rewatch, or an anime whose episode count MAL revised down: past the end is
  # still the end.
  test "past the last episode still completes it" do
    assert MAL.progress_fields(13, 12).status == "completed"
  end

  # Nothing here knows when a running series ends, so nothing here declares it
  # finished.
  test "an anime with no known episode count stays watching" do
    assert MAL.progress_fields(400, nil).status == "watching"
    assert MAL.progress_fields(5, 0).status == "watching"
  end
end
