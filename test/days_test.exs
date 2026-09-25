defmodule Laev.DaysTest do
  use ExUnit.Case, async: false

  alias Laev.Days

  setup do
    dir = Path.join(System.tmp_dir!(), "laev-days-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:laev_app, :data_dir)
    Application.put_env(:laev_app, :data_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if previous, do: Application.put_env(:laev_app, :data_dir, previous), else: Application.delete_env(:laev_app, :data_dir)
    end)

    {:ok, dir: dir}
  end

  defp log(dir, lines), do: File.write!(Path.join(dir, "watched.log"), Enum.join(lines, "\n") <> "\n")

  test "the appended lines add up per day", %{dir: dir} do
    log(dir, ["2026-09-24 300", "2026-09-24 240", "2026-09-25 300", "2026-09-25 5"])

    assert Days.totals() == %{~D[2026-09-24] => 540, ~D[2026-09-25] => 305}
  end

  test "junk in the log is skipped, not fatal", %{dir: dir} do
    log(dir, ["2026-09-25 300", "", "not a line", "2026-13-45 60", "2026-09-25 abc", "2026-09-25 5"])

    assert Days.totals() == %{~D[2026-09-25] => 305}
  end

  test "no log at all is simply nothing watched" do
    assert Days.totals() == %{}
  end

  test "recent fills in the quiet days, because a heatmap needs the gaps", %{dir: dir} do
    today = Days.today()
    log(dir, ["#{Date.add(today, -2)} 600", "#{today} 1200"])

    assert [{d0, 600}, {d1, 0}, {d2, 1200}] = Days.recent(3)
    assert d0 == Date.add(today, -2)
    assert d1 == Date.add(today, -1)
    assert d2 == today
  end

  test "recent is oldest first and ends today", %{dir: dir} do
    log(dir, [])
    days = Days.recent(10)

    assert length(days) == 10
    assert {Days.today(), 0} == List.last(days)
    assert Enum.map(days, &elem(&1, 0)) == Enum.sort_by(days, &Date.to_erl(elem(&1, 0))) |> Enum.map(&elem(&1, 0))
  end

  test "today is the local day, because that is what the player stamps" do
    assert Days.today() == NaiveDateTime.local_now() |> NaiveDateTime.to_date()
  end

  describe "streaks" do
    test "the longest run of days with something watched" do
      assert Days.streak([{~D[2026-09-20], 10}, {~D[2026-09-21], 0}, {~D[2026-09-22], 10}, {~D[2026-09-23], 10}]) == 2
    end

    test "a quiet stretch has no streak" do
      assert Days.streak([{~D[2026-09-20], 0}, {~D[2026-09-21], 0}]) == 0
    end

    test "every day counts as one long streak" do
      assert Days.streak(Enum.map(1..5, &{Date.add(~D[2026-09-01], &1), 60})) == 5
    end
  end

  test "a long log is folded into one line per day, with the same totals", %{dir: dir} do
    # A line every five seconds adds up; this is about a day and a half of them.
    lines = for i <- 1..5_200, do: "2026-09-#{rem(i, 20) + 1 |> Integer.to_string() |> String.pad_leading(2, "0")} 5"
    log(dir, lines)

    before = Days.totals()
    folded = File.read!(Path.join(dir, "watched.log")) |> String.split("\n", trim: true)

    assert length(folded) == 20, "one line per day after folding"
    assert Days.totals() == before, "folding must not change what was watched"
  end
end
