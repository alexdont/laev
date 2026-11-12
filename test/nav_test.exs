defmodule Laev.NavTest do
  use ExUnit.Case, async: false

  alias Laev.Nav

  # Laev's screens nest — home, a search, a title, its episodes, the player —
  # and esc from any of them went *home*. One slot held "where to come back to"
  # and `back/0` ignored it, so three levels in, esc threw away everything you
  # had typed to get there.

  setup do
    Nav.reset()
    Nav.forget_list()
    :ok
  end

  describe "the way back" do
    test "nothing pushed means home" do
      assert Nav.pop() == nil
      assert Nav.depth() == 0
    end

    test "one step out, not all the way" do
      Nav.push(fn -> :home end)
      Nav.push(fn -> :search end)
      Nav.push(fn -> :title end)

      assert Nav.pop().() == :title
      assert Nav.pop().() == :search
      assert Nav.pop().() == :home
      assert Nav.pop() == nil
    end

    test "peek leaves it where it is" do
      Nav.push(fn -> :search end)

      assert Nav.peek().() == :search
      assert Nav.peek().() == :search
      assert Nav.depth() == 1
    end

    # A list sets "come back here" for the title it opens. With a slot, esc
    # inside the list read the same slot and ran the list again, forever.
    test "a screen's own esc does not land on itself" do
      Nav.push(fn -> :home end)
      # the list opens a title, pushing itself
      Nav.push(fn -> :the_list end)
      # esc in the title: back to the list
      assert Nav.pop().() == :the_list
      # esc in the list: out to home, not the list again
      assert Nav.pop().() == :home
    end

    # A screen that returns normally rather than through esc leaves its entry
    # behind, so the depth has to be bounded.
    test "the stack is capped, oldest dropped" do
      for n <- 1..40, do: Nav.push(fn -> n end)

      assert Nav.depth() == 16
      assert Nav.pop().() == 40, "the most recent is still the way back"
    end

    test "reset forgets the way back" do
      Nav.push(fn -> :search end)
      Nav.reset()

      assert Nav.depth() == 0
      assert Nav.pop() == nil
    end

    test "and anything that is not a screen is ignored" do
      assert Nav.push(:not_a_function) == :ok
      assert Nav.push(fn _arg -> :wrong_arity end) == :ok
      assert Nav.depth() == 0
    end
  end

  describe "the list you came from" do
    test "is remembered with a name and a way back into it" do
      Nav.mark_list("Saved", fn -> :the_saved_list end)

      assert %{name: "Saved", open: open} = Nav.list()
      assert open.() == :the_saved_list
    end

    test "nothing picked from a list is nil" do
      assert Nav.list() == nil
    end

    # The stack moves while you navigate; the list is wanted *after* the play,
    # which is the whole point of it.
    test "it outlives the navigation" do
      Nav.mark_list("search: dune", fn -> :results end)
      Nav.push(fn -> :title end)
      Nav.pop()
      Nav.reset()

      assert %{name: "search: dune"} = Nav.list()
    end

    test "a later list replaces the earlier one" do
      Nav.mark_list("Saved", fn -> :saved end)
      Nav.mark_list("Watchlist", fn -> :watchlist end)

      assert Nav.list().name == "Watchlist"
    end

    test "and it can be forgotten" do
      Nav.mark_list("Saved", fn -> :saved end)
      Nav.forget_list()

      assert Nav.list() == nil
    end
  end

  # The wiring, read out of the source: the point is that every list screen
  # marks itself, because one that forgets gives no way back to it from the
  # player and that is invisible until somebody watches something.
  describe "the screens that are lists" do
    setup do
      {:ok, source: File.read!("lib/laev/cli.ex")}
    end

    test "Saved, the Watchlist and a search all mark themselves", %{source: source} do
      for name <- ["Saved", "Watchlist", "search: "] do
        assert source =~ "Nav.mark_list(\"#{name}",
               "the #{name} list does not offer itself back from the player"
      end
    end

    test "the player's menu offers it", %{source: source} do
      assert source =~ "origin = Laev.Nav.list()"
      assert source =~ "back to #{"#"}{origin.name}"
    end

    test "and esc goes through the stack rather than home", %{source: source} do
      assert source =~ "fun = Laev.Nav.pop() -> fun.()"
      refute source =~ "Process.get(:laev_screen)", "the old single slot is gone"
    end
  end
end
