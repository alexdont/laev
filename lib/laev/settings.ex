defmodule Laev.Settings do
  @moduledoc """
  Reading and changing what laev is configured with, from anywhere.

  The terminal has always had this: a Settings screen that lists every option,
  what it is set to, what it may be set to, and writes the change back so it
  applies at once. All of that logic sat inside the screen that drew it, which
  is fine until something else needs to ask the same questions — a web page
  wanting to render a form, say, or to tell somebody their Real-Debrid key was
  rejected before they try to play something.

  So the questions live here, answered as data: `all/0` describes every setting,
  `put/2` changes one, `validate/2` asks the service itself whether a key works.
  Within a scope all of that is that user's and nobody else's; without one it is
  this machine's, which is what the CLI has always meant by it.
  """

  alias Laev.{Config, Doctor, Scope}

  # The options a person can reasonably be shown, with what each will accept.
  # Taken from the same names the config file uses, so a form and a config file
  # and the terminal all describe one thing.
  @options [
    %{key: "LAEV_PLAYER", label: "Player", group: :playback, type: {:one_of, ~w(browser mpv vlc)}},
    %{key: "LAEV_AUTO_SOURCE", label: "Auto-pick the best source", group: :playback, type: {:one_of, ~w(on off)}},
    %{key: "LAEV_MAX_RESOLUTION", label: "Resolution ceiling", group: :playback, type: {:one_of, ~w(1080p 4K 720p any)}},
    %{key: "LAEV_STRICT_RESOLUTION", label: "Only list within the ceiling", group: :playback, type: {:one_of, ~w(off on)}},
    %{key: "LAEV_AUTOPLAY", label: "Autoplay the next episode", group: :playback, type: {:one_of, ~w(off on)}},
    %{key: "LAEV_SKIP", label: "Skip intros & credits", group: :playback, type: {:one_of, ~w(ask auto off)}},
    %{key: "LAEV_LANG", label: "Audio language", group: :language, type: :text},
    %{key: "LAEV_SUBS", label: "Subtitle language", group: :language, type: :text},
    %{key: "LAEV_POSTERS", label: "Poster previews", group: :appearance, type: {:one_of, ~w(auto ascii ascii-bg off)}},
    %{key: "LAEV_DOWNLOAD_DIR", label: "Download folder", group: :files, type: :text},
    %{key: "LAEV_MPV_ARGS", label: "Extra mpv arguments", group: :files, type: :text},
    %{key: "RD_TOKEN", label: "Real-Debrid token", group: :keys, type: :secret},
    %{key: "TORBOX_API_KEY", label: "TorBox key", group: :keys, type: :secret},
    %{key: "TMDB_API_KEY", label: "TMDB key", group: :keys, type: :secret},
    %{key: "OPENSUBTITLES_API_KEY", label: "OpenSubtitles key", group: :keys, type: :secret},
    %{key: "JIMAKU_API_KEY", label: "Jimaku key", group: :keys, type: :secret},
    %{key: "MAL_CLIENT_ID", label: "MyAnimeList client id", group: :keys, type: :secret},
    # The one value a second device needs: everything else — the watchlist, the
    # marks, the stats, and the API keys when they are carried — arrives with it.
    %{key: "LAEV_SYNC_TOKEN", label: "laev key", group: :sync, type: :secret},
    %{key: "LAEV_SYNC_URL", label: "Sync server", group: :sync, type: :text},
    %{key: "LAEV_SYNC_KEYS", label: "Carry API keys in the laev key", group: :sync, type: {:one_of, ~w(off on)}}
  ]

  @doc """
  Every setting, with its current value — ready to render as a form.

  A secret comes back masked rather than in full: a settings page has no reason
  to put somebody's debrid token back on the wire, and "set" or "not set" is
  what the page is actually asking.
  """
  def all(interface \\ :browser) do
    @options
    |> Enum.map(&narrow(&1, interface))
    |> Enum.map(fn option ->
      value = raw(option.key)

      option
      |> Map.put(:value, if(option.type == :secret, do: mask(value), else: value))
      |> Map.put(:set?, value not in [nil, ""])
    end)
  end

  # A player is only worth offering where it can actually be used: the browser
  # needs a page, and mpv and VLC need to be installed.
  defp narrow(%{key: "LAEV_PLAYER"} = option, interface),
    do: %{option | type: {:one_of, Laev.Playback.available(interface)}}

  defp narrow(option, _interface), do: option

  @doc "Settings grouped the way the screens group them."
  def groups(interface \\ :browser) do
    all(interface) |> Enum.group_by(& &1.group) |> Map.new(fn {group, options} -> {group, options} end)
  end

  @doc "One setting's current value, unmasked — for the code that uses it."
  def get(key), do: raw(key)

  @doc """
  Change a setting, for whoever is asking.

  Both halves, as the terminal does it: the value is written down so it
  survives a restart, and put into the running scope so it applies to the next
  thing that reads it rather than the next launch.
  """
  def put(key, value) do
    with {:ok, option} <- option(key),
         :ok <- accepts?(option, value) do
      # Written down and applied at once, in a scope exactly as in a terminal:
      # a change that only lived until the end of the request would be a
      # setting that never saved, which is worse than one that cannot be
      # changed at all.
      Config.write([{key, value}])
      Scope.set(Map.fetch!(Config.keys(), key), value)
      :ok
    end
  end

  @doc """
  Ask the service itself whether a key works, before it is relied on.

  `{:ok, detail}` carries what the service said about the account — the plan
  and the days left on it — which is the useful half of the answer.
  """
  def validate("RD_TOKEN", value), do: Doctor.check_rd(value)
  def validate("TORBOX_API_KEY", value), do: Doctor.check_torbox(value)
  def validate("TMDB_API_KEY", value), do: Doctor.check_tmdb(value)
  def validate(_key, _value), do: {:ok, "not checked"}

  @doc """
  Connect this user to a laev key and say whether it worked, in one call.

  The thing a "paste your key" box should do: nothing is saved unless the key
  actually reaches the server and returns a document.
  """
  def connect_sync(key, url \\ nil), do: Laev.Sync.connect(key, url)

  @doc """
  What the sync is doing, for a settings page to show without asking anyone to
  press anything: `{:ok, %{watchlist: 37, …}}`, or why not.
  """
  def sync_status, do: Laev.Sync.check()

  @doc "Which keys are missing for laev to be able to play anything at all."
  def missing_essentials do
    for key <- ["TMDB_API_KEY"] ++ debrid_requirement(), raw(key) in [nil, ""], do: key
  end

  defp debrid_requirement do
    if raw("RD_TOKEN") in [nil, ""] and raw("TORBOX_API_KEY") in [nil, ""], do: ["RD_TOKEN"], else: []
  end

  defp option(key) do
    case Enum.find(@options, &(&1.key == key)) do
      nil -> {:error, {:unknown_setting, key}}
      option -> {:ok, option}
    end
  end

  defp accepts?(%{type: {:one_of, allowed}} = option, value) do
    if value in allowed, do: :ok, else: {:error, {:must_be_one_of, option.key, allowed}}
  end

  defp accepts?(_option, value) when is_binary(value), do: :ok
  defp accepts?(option, _value), do: {:error, {:must_be_text, option.key}}

  defp raw(key) do
    case Map.fetch(Config.keys(), key) do
      {:ok, name} -> Scope.get(name)
      :error -> nil
    end
  end

  # Enough to recognise a key you pasted, not enough to be worth stealing.
  defp mask(value) when is_binary(value) and byte_size(value) > 8,
    do: String.slice(value, 0, 4) <> String.duplicate("•", 8) <> String.slice(value, -4, 4)

  defp mask(value) when is_binary(value) and value != "", do: "••••••••"
  defp mask(_value), do: nil
end
