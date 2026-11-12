defmodule Laev.MAL.Tokens do
  @moduledoc """
  Where a user's MyAnimeList tokens live: `mal.json` in their scope directory.

  `MyAnimeList` keeps no state of its own — it asks a store for the token and
  hands back a fresh one to persist — so this is laev's half of that bargain.
  The file is the one laev has always written, field for field, so a login made
  before the client was swapped still works.
  """

  @behaviour MyAnimeList.TokenStore

  alias MyAnimeList.Token

  # `@file` is a compiler attribute, not ours to use.
  @token_file "mal.json"

  @impl MyAnimeList.TokenStore
  def get_token(_owner) do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"access_token" => access} = stored} <- Jason.decode(body) do
      %Token{
        access_token: access,
        refresh_token: stored["refresh_token"],
        expires_at: expires_at(stored["expires_at"])
      }
    else
      _ -> nil
    end
  end

  @impl MyAnimeList.TokenStore
  def put_token(_owner, %Token{} = token) do
    File.write(
      path(),
      Jason.encode!(%{
        "access_token" => token.access_token,
        "refresh_token" => token.refresh_token,
        # Seconds since the epoch, as laev has always stored it. A token with
        # no expiry at all gets the far side of MAL's month, which is what the
        # old client assumed when MAL did not say.
        "expires_at" => unix(token.expires_at)
      })
    )
  end

  @impl MyAnimeList.TokenStore
  def delete_token(_owner) do
    File.rm(path())
    :ok
  end

  @doc "Whether there is a token at all — a login, in other words."
  def exists?, do: File.exists?(path())

  @doc "The file, under the scope's own directory."
  def path do
    dir = Laev.Scope.dir()
    File.mkdir_p!(dir)
    Path.join(dir, @token_file)
  end

  defp expires_at(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp expires_at(_other), do: nil

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_other), do: System.os_time(:second) + 2_400_000
end
