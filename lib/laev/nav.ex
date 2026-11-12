defmodule Laev.Nav do
  @moduledoc """
  Where **esc** goes, and which list you were looking at.

  Laev's screens are nested — home, a search, a title, its episodes, the player
  — and until now going back from any of them went *home*. One slot held "the
  screen to come back to", `back/0` ignored it and called `main_menu/0`, and
  three levels in, esc threw away everything you had typed to get there.

  So the screens are a stack. A screen pushes itself before opening another,
  esc pops one and runs it, and an empty stack is home — which is what esc at
  the top level should do anyway.

  ## Why a stack and not a slot

  A slot cannot answer both questions at once. The saved list sets "come back
  here" for the title screen it opens; if esc *inside the list* read the same
  slot it would run the list again, forever. With a stack, the list's own esc
  pops the entry its parent pushed and lands where it should.

  Depth is capped at `#{16}`: a screen that returns normally rather than through
  esc leaves its entry behind, and over a long session that would otherwise
  grow without end. The oldest goes first, so esc always knows at least the
  last few steps.

  ## The list you came from

  Separately from the stack, `mark_list/2` remembers the last *list* a title
  was chosen from — the search results, Saved, the Watchlist — so the player's
  menu can offer it back. Watching something from a list of twenty and having
  to search again to see the other nineteen is the thing this exists to stop.
  It survives the play, because it is wanted *after* the play; it is the stack
  that moves while you are navigating.
  """

  @screens :laev_screens
  @list :laev_origin_list
  @max_depth 16

  @doc "Remember `fun` as the screen to come back to, and open something else."
  def push(fun) when is_function(fun, 0) do
    stack = [fun | stack()] |> Enum.take(@max_depth)
    Process.put(@screens, stack)
    :ok
  end

  def push(_other), do: :ok

  @doc """
  The screen to go back to, removed from the stack, or nil at the top level.
  """
  def pop do
    case stack() do
      [fun | rest] ->
        Process.put(@screens, rest)
        fun

      [] ->
        nil
    end
  end

  @doc "The screen esc would run, left where it is."
  def peek do
    case stack() do
      [fun | _rest] -> fun
      [] -> nil
    end
  end

  @doc "How many steps back there are."
  def depth, do: length(stack())

  @doc "Forget the way back — for a screen that is starting again from home."
  def reset do
    Process.delete(@screens)
    :ok
  end

  @doc """
  Remember the list a title was picked from: a name to show and a function that
  opens it again where it was.
  """
  def mark_list(name, fun) when is_binary(name) and is_function(fun, 0) do
    Process.put(@list, %{name: name, open: fun})
    :ok
  end

  def mark_list(_name, _fun), do: :ok

  @doc "The list a title was picked from, as `%{name:, open:}`, or nil."
  def list, do: Process.get(@list)

  @doc "Forget it — nothing was picked from a list."
  def forget_list do
    Process.delete(@list)
    :ok
  end

  defp stack do
    case Process.get(@screens) do
      stack when is_list(stack) -> stack
      _ -> []
    end
  end
end
