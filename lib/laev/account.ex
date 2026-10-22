defmodule Laev.Account do
  @moduledoc """
  Is the debrid subscription still good?

  Every source laev plays goes through Real-Debrid or TorBox, and when the
  subscription behind them lapses the APIs stop resolving — a user whose plan
  ran out mid-session watched laev try source after source, each one answered
  the same way, with nothing on screen to say why. The answer was one request
  away the whole time: both providers report their own expiry date.

  So it is asked once a day and remembered. Once a day rather than once a
  session because a session can outlive the subscription: laev left open in a
  window overnight is laev holding an answer from yesterday, which is exactly
  how somebody ends up staring at failures for a plan that expired at midnight.
  The cache is keyed by the local date — when the date changes, the answer is
  stale by definition, whether the app has been running for ten minutes or a
  month.

  Nothing here blocks on the network where a screen is waiting: `ensure/0` is
  called at the edges (launch, and before a source search), and everything in
  the hot path reads `blocked/0`, which only ever consults what is already
  known.
  """

  alias Laev.{Doctor, RD, Torbox}

  @key {__MODULE__, :status}

  @doc """
  The subscription state, checked at most once a day: `:ok`, `{:expired,
  detail}` when a provider says the plan has lapsed, or `{:unknown, detail}`
  when nothing could be reached — which is not the same thing and must never be
  treated as one. A network laev can't reach is a network the provider can't be
  asked about.
  """
  def ensure do
    case :persistent_term.get(@key, nil) do
      {date, status} -> if date == today(), do: status, else: refresh()
      _ -> refresh()
    end
  end

  @doc "Ask the providers now, whatever is remembered."
  def refresh do
    status = check()
    :persistent_term.put(@key, {today(), status})
    status
  end

  @doc """
  What is already known, without asking anyone: `{:expired, detail}` or nil.

  For the paths that run per source, where a request would be both slow and
  pointless. An unchecked or unreachable account is not blocked — being unsure
  is never a reason to refuse to play something.
  """
  def blocked do
    case :persistent_term.get(@key, nil) do
      {_date, {:expired, _detail} = expired} -> expired
      _ -> nil
    end
  end

  @doc "Check in the background, for the moments worth knowing early."
  def warm do
    Laev.Scope.spawn(fn -> ensure() end)
    :ok
  end

  @doc "Forget what was checked — for tests, and for a key that just changed."
  def forget, do: :persistent_term.erase(@key)

  # Every configured provider is asked. One good subscription is enough to
  # play — TorBox alone is a working laev — so only a user with no working
  # provider at all is blocked.
  defp check do
    results =
      [
        RD.configured?() && {"Real-Debrid", fn -> Doctor.check_rd(token(:rd)) end},
        Torbox.configured?() && {"TorBox", fn -> Doctor.check_torbox(token(:torbox)) end}
      ]
      |> Enum.filter(& &1)
      |> Enum.map(fn {name, check} -> {name, check.()} end)

    cond do
      results == [] -> {:unknown, "no provider configured"}
      Enum.any?(results, &match?({_name, {:ok, _detail}}, &1)) -> :ok
      true -> verdict(results)
    end
  rescue
    _ -> {:unknown, "could not be checked"}
  end

  # Nothing answered yes. Whether that is an expired plan or an unreachable
  # network decides whether laev stops someone or stays out of the way, so the
  # two are told apart by what the provider actually said: a rejection is an
  # answer, a timeout is not.
  defp verdict(results) do
    rejections =
      for {name, {:error, detail}} <- results, rejection?(detail), do: "#{name}: #{detail}"

    if rejections == [],
      do: {:unknown, results |> Enum.map_join("; ", fn {name, {_, detail}} -> "#{name}: #{detail}" end)},
      else: {:expired, Enum.join(rejections, "; ")}
  end

  defp rejection?(detail) when is_binary(detail), do: detail =~ ~r/\b(401|403|rejected|locked|not premium)\b/
  defp rejection?(_detail), do: false

  defp token(:rd), do: Laev.Scope.get(:rd_token)
  defp token(:torbox), do: Laev.Scope.get(:torbox_api_key)

  defp today, do: Laev.Days.today()
end
