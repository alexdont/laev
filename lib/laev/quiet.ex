defmodule Laev.Quiet do
  @moduledoc """
  Nothing else writes to the terminal while a picker owns it.

  fzf draws a whole frame and tracks the selected row itself. A line printed
  underneath it from somewhere else scrolls the screen without fzf knowing, so
  what you see ends up one row off what fzf thinks is selected: the arrow keys
  move to the wrong place and enter picks the row above. On a slow link — over
  SSH from a phone or a Mac terminal — the offset frame can sit there for a
  while, which is when it gets noticed.

  Background work is what does it. A sync push and a MyAnimeList scrobble both
  land about five seconds after a film ends, with the post-play menu already
  open, and each used to print a line about it.

  So while a picker is up, notes from anywhere else are dropped rather than
  printed. They are status chatter — a sync that didn't go through is still
  visible in `laev sync status` and goes again on the next launch — and a
  corrupted menu costs more than the line is worth.

  Only the process running the picker holds it, and the flag is global to the
  run, because the writers are separate processes.
  """

  @key {__MODULE__, :held}

  @doc "Run `fun` with the terminal reserved. Always releases it."
  def hold(fun) when is_function(fun, 0) do
    # A count rather than a flag: one picker opening inside another must not
    # hand the screen back when the inner one closes.
    :persistent_term.put(@key, holders() + 1)

    try do
      fun.()
    after
      :persistent_term.put(@key, max(holders() - 1, 0))
    end
  end

  @doc "True while a picker owns the screen."
  def held?, do: holders() > 0

  defp holders do
    case :persistent_term.get(@key, 0) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc "Write a background note to stderr — unless a picker owns the screen."
  def puts(iodata) do
    unless held?(), do: IO.puts(:stderr, iodata)
    :ok
  end
end
