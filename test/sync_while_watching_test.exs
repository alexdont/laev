defmodule Laev.SyncWhileWatchingTest do
  use ExUnit.Case, async: false

  alias Laev.Scope

  # Watching four episodes on one machine used to leave the other machines
  # reading "one episode in" until the CLI was closed, because the pushes that
  # were supposed to happen during the session never fired. Two reasons, both
  # here: the per-change push was gated on a setting almost nobody has on, and
  # two of the three ways to start a player skipped the push entirely.

  describe "a change pushed while the session is still open" do
    # `live` is off by default; `auto` is what setup turns on. Gating the
    # per-change push on `live` alone meant eighteen call sites — marking
    # watched, pinning, holds, ratings — silently did nothing for everyone
    # running the default configuration.
    test "auto-sync alone is enough" do
      assert push?(auto: "on", live: "off"), "auto on: a mark leaves the device when it is made"
      assert push?(auto: "off", live: "on"), "live on: unchanged, it always did"
      assert push?(auto: "on", live: "on")
    end

    test "with both switches off nothing is pushed until a sync is asked for" do
      refute push?(auto: "off", live: "off")
    end

    # A delta push has nowhere to go without an endpoint, whatever the
    # switches say.
    test "and nothing is pushed without somewhere to push it" do
      Scope.with_overrides(%{sync_url: nil, sync_token: nil, sync_auto: "on", sync_live: "on"}, fn ->
        refute Laev.Sync.push_now?()
        assert Laev.Sync.live_push() == :skip
      end)
    end
  end

  describe "every way of starting a player is tracked" do
    # `continue_entry` (the Continue row) and `reopen` (adopting what is
    # already playing) each launched a player and then went straight to the
    # menu: no MAL scrobble, no resume push, and no watcher to push the
    # finished episode. Only the search path was wired up. Rather than trust
    # three copies to stay in step, every launch site now goes through
    # `track_playback/1`, and this reads the source to make sure it still does.
    test "a function that launches a player also calls track_playback" do
      for {name, arity, body} <- defs_in("lib/laev/cli.ex"),
          calls?(body, :"Player.play"),
          # `laev play <magnet|url>` has no context — no title, so nothing to
          # resume, scrobble or sync. Everything else is a real watch.
          not plays_without_context?(body) do
        assert calls?(body, :track_playback),
               "#{name}/#{arity} starts a player without tracking it: " <>
                 "resuming there would scrobble nothing and sync nothing until exit"
      end
    end

    test "the sites that were missing it are the ones fixed" do
      defs = defs_in("lib/laev/cli.ex")

      for name <- [:continue_entry, :reopen] do
        assert Enum.any?(defs, fn {n, _a, body} -> n == name and calls?(body, :track_playback) end),
               "#{name} must track the playback it starts"
      end
    end
  end

  defp push?(auto: auto, live: live) do
    Scope.with_overrides(
      %{sync_url: "https://example.test/laev", sync_token: "laev_t", sync_auto: auto, sync_live: live},
      &Laev.Sync.push_now?/0
    )
  end

  # Top-level function definitions, as {name, arity, body-ast}.
  defp defs_in(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_, defs} =
      Macro.prewalk(ast, [], fn
        {op, _, [head, body]} = node, acc when op in [:def, :defp] ->
          {name, arity} = signature(head)
          {node, [{name, arity, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp signature({:when, _, [head | _]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}
  defp signature(_), do: {:unknown, 0}

  # Whether the body calls the named function, dotted names included
  # (`Player.play` as well as a bare `track_playback`).
  defp calls?(body, wanted) do
    {_, found} =
      Macro.prewalk(body, false, fn node, found ->
        {node, found or called_name(node) == wanted}
      end)

    found
  end

  defp called_name({{:., _, [{:__aliases__, _, mods}, fun]}, _, _}),
    do: :"#{Enum.join(mods, ".")}.#{fun}"

  defp called_name({name, _, args}) when is_atom(name) and is_list(args), do: name
  defp called_name(_), do: nil

  # `Player.play(nil, url, [])` — no context, so nothing to track.
  defp plays_without_context?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, mods}, :play]}, _, [nil | _]} = node, _ when mods != [] ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end
end
