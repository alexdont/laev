defmodule Laev.LogQuietTest do
  use ExUnit.Case, async: false

  # laev draws over the whole terminal, so anything that writes to it writes
  # over a picker. Handlers are the obvious half, and `Laev.Log` already removed
  # them. The half that bit: a *filter* runs before the handlers, and when one
  # crashes the logger reports it with `erlang:display/1`, straight down file
  # descriptor 2 — past every handler, and past anything laev could install:
  #
  #     Logger - error: {removed_failing_filter,logger_translator}
  #
  # The filter that crashes is Elixir's `logger_translator`, and it crashes for
  # the reason `Laev.Log` exists at all: it reaches for the pretty-printing
  # machinery, out of the unpacked payload a standalone binary runs from, after
  # an update has replaced that directory. That line cannot be captured or
  # redirected from inside the VM, so these tests are about the filters being
  # gone rather than about the output.

  setup do
    handlers = for id <- :logger.get_handler_ids(), do: :logger.get_handler_config(id)
    filters = :logger.get_primary_config()[:filters] || []

    # The logger is one global thing and `install/0` empties it. Put back what
    # was there, or this file decides how the rest of the suite logs.
    on_exit(fn ->
      for id <- :logger.get_handler_ids(), do: :logger.remove_handler(id)
      for {:ok, config} <- handlers, do: :logger.add_handler(config.id, config.module, config)

      for {id, _} <- :logger.get_primary_config()[:filters] || [],
          do: :logger.remove_primary_filter(id)

      for {id, filter} <- filters, do: :logger.add_primary_filter(id, filter)
    end)

    :ok
  end

  # The end state a user gets: laev's own boot installs the log, and by the time
  # anything can be logged there is no filter left to crash. Elixir's
  # `logger_translator` is installed before this and is gone by now.
  test "a running laev has no primary filter left to crash" do
    assert :logger.get_primary_config()[:filters] == []
  end

  test "install removes the filters it finds" do
    :logger.add_primary_filter(:laev_test_filter, {fn event, _config -> event end, []})

    assert Enum.map(:logger.get_primary_config()[:filters], &elem(&1, 0)) == [:laev_test_filter]

    Laev.Log.install()

    assert :logger.get_primary_config()[:filters] == [],
           "a filter that is not there cannot crash, and nothing in laev needs one"
  end

  test "and what is logged still reaches the file handler" do
    Laev.Log.install()

    assert :logger.get_handler_ids() == [:laev_file],
           "ours, and only ours — every other handler writes to the screen"

    # No filters and `filter_default: :log` means an event is judged by the
    # handler's level alone, which is what the filters were in the way of.
    assert :logger.get_primary_config()[:filter_default] == :log
  end
end
