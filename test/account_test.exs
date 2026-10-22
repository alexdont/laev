defmodule Laev.AccountTest do
  use ExUnit.Case, async: false

  alias Laev.Account

  setup do
    Account.forget()

    # No providers, so a re-check reaches its own conclusion instead of this
    # machine's actual subscription.
    keys = for key <- [:rd_token, :torbox_api_key], do: {key, Application.get_env(:laev, key)}
    for {key, _} <- keys, do: Application.delete_env(:laev, key)

    on_exit(fn ->
      Account.forget()
      for {key, value} <- keys, value != nil, do: Application.put_env(:laev, key, value)
    end)

    :ok
  end

  defp remember(date, status), do: :persistent_term.put({Account, :status}, {date, status})

  # The whole point of the day key: a session can outlive the subscription, and
  # laev left open overnight was answering from yesterday.
  test "a cached answer is kept for the day it was taken" do
    remember(Laev.Days.today(), {:expired, "Real-Debrid: token rejected (401)"})

    assert Account.ensure() == {:expired, "Real-Debrid: token rejected (401)"}
  end

  test "yesterday's answer is not an answer" do
    remember(Date.add(Laev.Days.today(), -1), :ok)

    assert Account.ensure() == {:unknown, "no provider configured"}
  end

  # The hot path reads this once per source; it must never reach the network,
  # and must never block anything on an answer nobody has taken yet.
  test "what is already known, and nothing more" do
    assert Account.blocked() == nil

    remember(Laev.Days.today(), {:expired, "TorBox: key rejected (403)"})
    assert Account.blocked() == {:expired, "TorBox: key rejected (403)"}
  end

  # Being unsure is not a reason to refuse to play something: an unreachable
  # provider is a network problem, not an expired plan.
  test "unreachable is not expired" do
    remember(Laev.Days.today(), {:unknown, "Real-Debrid: unreachable"})

    assert Account.blocked() == nil
    assert Account.ensure() == {:unknown, "Real-Debrid: unreachable"}
  end

  test "an account nobody has checked blocks nothing" do
    assert Account.blocked() == nil
  end
end
