defmodule Laev.Log do
  @moduledoc """
  Keep the logger off the screen, and keep it from taking the app down with it.

  Two things go wrong when a terminal app logs to its own terminal. The small
  one is a stray line scrolling a picker out from under the cursor. The large
  one is what happened on a Mac left open overnight: a TLS alert was reported
  when the laptop's connections died, the handler went to format it, and the
  modules formatting needs — `io_lib_pretty`, `Inspect.Opts`, neither resident
  at boot — could not be loaded, because they live in the unpacked payload the
  standalone binary runs from and the system had cleaned that up hours before.
  The formatter crashed, the crash was logged, and that log crashed the same
  way. Several thousand times, over the whole screen.

  So nothing writes to the terminal. What there is to say goes to
  `~/.laev/laev.log`, through a handler written here rather than one of OTP's:
  a handler is a module with `log/2`, and ours formats with no lazily-loaded
  machinery, cannot ask for a module that isn't there, and treats its own
  failure as nothing worth mentioning. The formatting modules are pulled into
  memory at boot anyway, for everything else that might reach for them.
  """

  @behaviour :logger_handler

  @filename "laev.log"
  # Enough to hold the run-up to whatever went wrong, small enough to forget.
  # One previous file is kept, so a crash loop can't bury what started it.
  @max_bytes 256 * 1024
  @max_line 2_000

  # Loaded now rather than at the moment something has gone wrong — which is
  # exactly when the code to load them is least likely to still be reachable.
  # The first two are the ones the Mac crash named.
  @formatting [
    :io_lib,
    :io_lib_format,
    :io_lib_pretty,
    :unicode_util,
    Inspect.Opts,
    Inspect.Algebra
  ]

  @doc "Silence the terminal, take the log to a file, preload the formatters."
  def install do
    preload()

    # Every handler there is writes to stdout or stderr — both of them the
    # screen. The ssl app adds its own, which config cannot refuse.
    for id <- :logger.get_handler_ids(), do: :logger.remove_handler(id)

    :logger.add_handler(:laev_file, __MODULE__, %{level: :warning})
    :ok
  rescue
    # A logger that won't set up is no reason not to start: the silence is the
    # half that matters, and it is already done.
    _ -> :ok
  end

  @doc "Where the log is, for anyone asking what went wrong."
  def path do
    dir = Laev.Scope.dir()
    File.mkdir_p!(dir)
    Path.join(dir, @filename)
  end

  @impl :logger_handler
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    file = path()
    rotate(file)
    File.write(file, [stamp(meta), " ", pad(level), " ", message(msg), "\n"], [:append])
    :ok
  rescue
    # Whatever just happened, it is not worth a second crash on the way to
    # recording the first.
    _ -> :ok
  end

  # The three shapes a log message arrives in.
  defp message({:string, chars}), do: trim(chars)
  defp message({:report, report}), do: trim(safe_inspect(report))
  defp message({format, args}), do: trim(safe_format(format, args))
  defp message(other), do: trim(safe_inspect(other))

  defp safe_format(format, args) do
    :io_lib.format(format, args)
  rescue
    _ -> safe_inspect({format, args})
  end

  defp safe_inspect(term) do
    inspect(term, limit: 20, printable_limit: 400)
  rescue
    # Inspect itself is the thing that failed on that Mac. Say what little can
    # be said without it rather than nothing at all.
    _ -> "<unprintable #{:erlang.phash2(term)}>"
  end

  defp trim(chars) do
    chars
    |> IO.iodata_to_binary()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.slice(0, @max_line)
  rescue
    _ -> "<unformattable>"
  end

  defp pad(level), do: level |> to_string() |> String.pad_trailing(8)

  defp stamp(%{time: micros}) when is_integer(micros) do
    micros |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  rescue
    _ -> "?"
  end

  defp stamp(_meta), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp rotate(file) do
    case File.stat(file) do
      {:ok, %{size: size}} when size >= @max_bytes -> File.rename(file, file <> ".1")
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp preload, do: Enum.each(@formatting, &Code.ensure_loaded/1)
end
