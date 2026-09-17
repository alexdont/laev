defmodule Laev.CLI do
  @moduledoc """
  The `laev` command-line interface.

  Emits JSON on stdout (one document per invocation) so frontends — the
  Omarchy overlay, scripts, a future TUI — can consume it. `--pretty` renders
  a human-readable listing instead.
  """

  alias Laev.{Config, Kitsu, Player, Providers, RD, Sources, Tmdb}

  @backends %{"apibay" => :apibay, "nyaa" => :nyaa, "anime" => :anime}

  def main(argv) do
    case argv do
      ["search" | rest] -> search(rest)
      ["watch" | rest] -> watch(rest)
      ["download" | rest] -> download(rest)
      ["featured" | _] -> featured()
      ["calendar" | _] -> calendar()
      ["continue" | _] -> continue()
      ["resume" | _] -> resume()
      ["resolve" | rest] -> resolve(rest)
      ["play" | rest] -> play(rest)
      ["colors" | _] -> debug_colors()
      ["config" | _] -> config()
      ["setup" | _] -> setup()
      ["doctor" | _] -> doctor()
      ["update" | _] -> update()
      ["mal" | rest] -> mal(rest)
      ["sync" | rest] -> sync_cmd(rest)
      ["help" | _] -> usage(0)
      ["--help" | _] -> usage(0)
      [] -> if tty?(), do: main_menu(), else: usage(1)
      [other | _] -> die("unknown command: #{other} (try: laev help)")
    end
  end

  # ── main menu (bare `laev` at a terminal) ─────────────────────────

  # The LAEV ship mark over the main menu (laev = ship) — chafa block render
  # of the sailboat + wordmark (margin-trimmed, quadrant/half glyphs, max
  # work factor), pre-rendered into source. Lit row by row in the marquee
  # red→gold gradient.
  @banner [
    "      ▅▗▖        ▐██▏          ████▖     █████████ ▐██▙     ▗██▛",
    "    ▗█▊▐█▅       ▐██▏         ▟██▜██     ██▉▔▔▔▔▔▔  ▜██▖    ███▘",
    "   ▗██▊▐██▙      ▐██▏        ▗██▋▝██▙    ██▉▁▁▁▁▁▁  ▕███   ▟██▌ ",
    "  ▟███▊▐████▖    ▐██▏        ███▏ ▜██▖   ████████▌   ▐██▋ ▗██▛  ",
    " ▝▀▀▀▀▘▝▀▀▀▀▀    ▐██▏       ▟███▆▆▇███   ██▉▔▔▔▔▔     ▜██▏▟██▘  ",
    " ▀███████████▀   ▐██▂▂▂▂▂▂ ▗██▛▀▀▀▀▜██▙  ██▉▂▂▂▂▂▂    ▝██▙██▌   ",
    "  ▝▜███████▛▘    ▐███████▉ ███▘     ▜██▖ █████████     ▐███▛    "
  ]
  # Fixed red→gold anchors used when the terminal won't report its palette.
  @ramp_fallback {{0xE0, 0x30, 0x00}, {0xFF, 0xD0, 0x00}}

  defp print_banner do
    {_rows, cols} = tty_size()
    lines = banner_lines()
    width = lines |> Enum.map(&String.length/1) |> Enum.max()

    if cols >= width + 6 do
      IO.puts(:stderr, "")
      total = length(lines)
      panel = if cols >= width + 46, do: week_panel(cols), else: []
      {c0, c1} = ramp_anchors()

      lines
      |> Enum.with_index()
      |> Enum.each(fn {line, i} ->
        frac = if total > 1, do: i / (total - 1), else: 0.0
        IO.puts(:stderr, "  " <> colorize_banner(line, lerp_rgb(c0, c1, frac)) <> panel_at(panel, i))
      end)

      indent = 2 + max(div(width - 24, 2), 0)

      IO.puts(
        :stderr,
        IO.ANSI.format([
          :faint,
          :italic,
          String.duplicate(" ", indent) <> "· your terminal cinema ·",
          :reset
        ])
      )
    end
  end

  # ~/.laev/banner.txt overrides the built-in art — edit it by hand, rerun
  # laev, see it live; delete the file to get the built-in back. Rows are
  # padded to a uniform width so the gradient/panel alignment holds.
  defp banner_lines do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")

    with {:ok, contents} <- File.read(Path.join(dir, "banner.txt")),
         rows = contents |> String.split("\n") |> trim_blank_edges(),
         false <- rows == [] do
      w = rows |> Enum.map(&String.length/1) |> Enum.max()
      Enum.map(rows, &String.pad_trailing(&1, w))
    else
      _ -> @banner
    end
  rescue
    _ -> @banner
  end

  defp trim_blank_edges(rows) do
    blank? = &(String.trim(&1) == "")
    rows |> Enum.drop_while(blank?) |> Enum.reverse() |> Enum.drop_while(blank?) |> Enum.reverse()
  end


  # "this week" beside the banner: the next-7-days pulse from the calendar
  # cache (read-only — the home screen never fetches). Absent when nothing
  # is due, the terminal is narrow, or nothing is cached yet.
  defp week_panel(cols) do
    if cols >= 100 and Tmdb.configured?() do
      rows = Laev.Calendar.cached_events()

      case Enum.map(rows, &panel_row/1) do
        [] ->
          []

        formatted ->
          {shown, rest} = Enum.split(formatted, 6)

          more =
            if rest == [],
              do: [],
              else: [
                IO.iodata_to_binary(
                  IO.ANSI.format_fragment([:faint, "… #{length(rest)} more — ⧉ calendar", :reset])
                )
              ]

          header =
            IO.iodata_to_binary(IO.ANSI.format_fragment([:bright, "this week", :reset]))

          [header | shown] ++ more
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp panel_at(panel, i) do
    case Enum.at(panel, i) do
      nil -> ""
      row -> "    " <> row
    end
  end

  defp panel_row(ev) do
    date = Date.from_iso8601!(ev["date"])
    label = short_event(ev)

    {style, prefix} =
      case Date.compare(date, Date.utc_today()) do
        :lt ->
          {[:green], "out ▶"}

        :eq ->
          {[:green, :bright], "today"}

        :gt ->
          days = Date.diff(date, Date.utc_today())
          {[:yellow], "#{Elixir.Calendar.strftime(date, "%a")} ·#{days}d"}
      end

    IO.iodata_to_binary(
      IO.ANSI.format_fragment(style ++ ["▪ ", String.pad_trailing(prefix, 8), :reset, label])
    )
  end

  defp colorize_banner(line, {r, g, b}) do
    code = "\e[38;2;#{r};#{g};#{b}m"
    shadow = IO.ANSI.light_black()

    line
    |> String.graphemes()
    |> Enum.map_join(fn
      " " -> " "
      "_" -> shadow <> "_"
      stroke -> code <> stroke
    end)
    |> Kernel.<>(IO.ANSI.reset())
  end

  defp lerp_rgb({r0, g0, b0}, {r1, g1, b1}, t) do
    {round(r0 + (r1 - r0) * t), round(g0 + (g1 - g0) * t), round(b0 + (b1 - b0) * t)}
  end

  # Marquee endpoints from the LIVE terminal palette (color 1 = red, 3 =
  # yellow) via an OSC-4 query — so the gradient is interpolated through
  # *this theme's* colors and re-tints when omarchy switches themes. Falls
  # back to a fixed red→gold ramp if the terminal doesn't answer.
  #
  # Accent gradient: query the theme's 6 main palette colors and gradient
  # between its two most-saturated, most-different-hue ones — so the fish
  # takes on the theme's dominant hues (cool theme → cool fish, warm → warm)
  # instead of a forced red→gold. Monochrome/greyscale themes fall back.
  defp ramp_anchors do
    case logo_override() do
      {_, _} = pair -> pair
      _ -> auto_ramp_anchors()
    end
  end

  # LAEV_LOGO_COLORS="#rrggbb,#rrggbb" forces the gradient endpoints — a
  # reliable manual path when the terminal won't answer the palette query.
  defp logo_override do
    with s when is_binary(s) <- Application.get_env(:laev_app, :logo_colors),
         [a, b] <- s |> String.split(",", parts: 2) |> Enum.map(&parse_hex/1),
         true <- a != nil and b != nil do
      {a, b}
    else
      _ -> nil
    end
  end

  defp parse_hex(s) do
    case s |> String.trim() |> String.trim_leading("#") do
      <<r::binary-2, g::binary-2, b::binary-2>> ->
        with {rr, ""} <- Integer.parse(r, 16),
             {gg, ""} <- Integer.parse(g, 16),
             {bb, ""} <- Integer.parse(b, 16),
             do: {rr, gg, bb},
             else: (_ -> nil)

      _ ->
        nil
    end
  end

  defp auto_ramp_anchors do
    # Prefer the terminal's config file (reliable, re-themes when the config
    # symlink repoints — e.g. omarchy theme switching); fall back to the live
    # OSC-4 query for terminals we don't parse.
    palette = case config_palette() do
      p when map_size(p) >= 2 -> p
      _ -> query_palette()
    end

    saturated =
      palette
      |> Map.values()
      |> Enum.filter(fn rgb -> saturation(rgb) >= 0.25 end)
      |> Enum.sort_by(&saturation/1, :desc)

    case saturated do
      [] ->
        @ramp_fallback

      [only] ->
        # One saturated hue: gradient from a darker to brighter shade of it.
        {scale(only, 0.65), only}

      [a | rest] ->
        b = Enum.max_by(rest, &hue_distance(a, &1))
        {a, b}
    end
  rescue
    _ -> @ramp_fallback
  end

  # The theme's palette read from the terminal's own config file — reliable
  # and no tty round-trip (the OSC-4 query can't be read back from a BEAM
  # child). Tries the config-file terminals that exist; the one matching the
  # current terminal ($TERM/$TERM_PROGRAM) is tried first. Re-read each
  # launch, so a theme switch (e.g. omarchy repointing foot's include) is
  # picked up automatically. %{1..6 => {r,g,b}}.
  #
  # Covered: foot, kitty, ghostty, alacritty, wezterm (Linux + macOS, same
  # ~/.config files). Not auto-readable: macOS Terminal/iTerm2, Windows
  # Terminal — those use LAEV_LOGO_COLORS or the red→gold fallback.
  defp config_palette do
    Enum.find_value(terminal_sources(), %{}, fn read ->
      case read.() do
        p when map_size(p) >= 2 -> p
        _ -> nil
      end
    end)
  rescue
    _ -> %{}
  end

  # Config readers, ordered with the active terminal first.
  defp terminal_sources do
    cfg = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    term = String.downcase((System.get_env("TERM") || "") <> " " <> (System.get_env("TERM_PROGRAM") || ""))

    all = [
      {"foot", fn -> palette_ini_kv(Path.join([cfg, "foot", "foot.ini"]), ~r/(?:regular|color)/) end},
      {"kitty", fn -> palette_kitty(Path.join([cfg, "kitty", "kitty.conf"])) end},
      {"ghostty", fn -> palette_ghostty(Path.join([cfg, "ghostty", "config"])) end},
      {"alacritty", fn -> palette_alacritty(cfg) end},
      {"wezterm", fn -> palette_alacritty(cfg) end}
    ]

    {active, rest} = Enum.split_with(all, fn {name, _} -> String.contains?(term, name) end)
    Enum.map(active ++ rest, fn {_name, read} -> read end)
  end

  # foot-style INI: `regularN = #rrggbb` / `colorN = rrggbb`, following include=.
  defp palette_ini_kv(base, prefix) do
    [base | ini_includes(base)]
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, body} ->
          for [_, n, hex] <- Regex.scan(~r/^\s*#{Regex.source(prefix)}([1-6])\s*=\s*#?([0-9a-fA-F]{6})/m, body),
              rgb = parse_hex(hex),
              rgb != nil,
              do: {String.to_integer(n), rgb}

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  # kitty: `color1 #rrggbb`, following `include`.
  defp palette_kitty(base) do
    includes =
      case File.read(base) do
        {:ok, body} ->
          Regex.scan(~r/^\s*include\s+(.+)$/m, body)
          |> Enum.map(fn [_, p] -> Path.expand(expand_path(String.trim(p)), Path.dirname(base)) end)

        _ ->
          []
      end

    [base | includes]
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, body} ->
          for [_, n, hex] <- Regex.scan(~r/^\s*color([1-6])\s+#?([0-9a-fA-F]{6})/m, body),
              rgb = parse_hex(hex),
              rgb != nil,
              do: {String.to_integer(n), rgb}

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  # ghostty: `palette = 1=#rrggbb`.
  defp palette_ghostty(path) do
    case File.read(path) do
      {:ok, body} ->
        for [_, n, hex] <- Regex.scan(~r/palette\s*=\s*([1-6])=#?([0-9a-fA-F]{6})/m, body),
            rgb = parse_hex(hex),
            rgb != nil,
            into: %{},
            do: {String.to_integer(n), rgb}

      _ ->
        %{}
    end
  end

  # alacritty (TOML/YAML) & wezterm: named normal colors under a colors block.
  defp palette_alacritty(cfg) do
    names = %{"red" => 1, "green" => 2, "yellow" => 3, "blue" => 4, "magenta" => 5, "cyan" => 6}

    paths =
      [
        Path.join([cfg, "alacritty", "alacritty.toml"]),
        Path.join([cfg, "alacritty", "alacritty.yml"]),
        Path.join([cfg, "wezterm", "wezterm.lua"])
      ]

    Enum.reduce(paths, %{}, fn path, acc ->
      case File.read(path) do
        {:ok, body} ->
          found =
            for {name, n} <- names,
                [_, hex] <- Regex.scan(~r/#{name}\s*[:=]\s*["']#?([0-9a-fA-F]{6})["']/i, body),
                rgb = parse_hex(hex),
                rgb != nil,
                into: %{},
                do: {n, rgb}

          Map.merge(found, acc)

        _ ->
          acc
      end
    end)
  end

  defp ini_includes(path) do
    case File.read(path) do
      {:ok, body} ->
        Regex.scan(~r/^\s*include\s*=\s*(.+)$/m, body)
        |> Enum.map(fn [_, p] -> expand_path(String.trim(p)) end)

      _ ->
        []
    end
  end

  defp expand_path(p) do
    p
    |> String.replace_prefix("~", System.user_home!())
    |> String.replace("$HOME", System.user_home!())
  end

  # One combined OSC-4 query for palette colors 1..6 (red green yellow blue
  # magenta cyan) — a single terminal round-trip. %{index => {r,g,b}}.
  defp query_palette do
    osc = "\e]4;1;?;2;?;3;?;4;?;5;?;6;?\e\\"

    # Send the query, let the terminal's reply land in the tty buffer, then
    # read it. `dd` with min 0/time does one bounded read of whatever arrived
    # — unlike `head`, which quits on the first (pre-reply) empty read.
    script =
      "old=$(stty -g </dev/tty) || exit 1; " <>
        "stty raw -echo min 0 time 4 </dev/tty; " <>
        "printf %s #{inspect(osc)} >/dev/tty; " <>
        "sleep 0.2; " <>
        "dd bs=1024 count=1 </dev/tty 2>/dev/null; " <>
        "stty \"$old\" </dev/tty"

    case System.cmd("sh", ["-c", script], stderr_to_stdout: true) do
      {out, 0} -> parse_palette(out)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # Each response: ESC ]4;N;rgb:RRRR/GGGG/BBBB ST — 16-bit channels, hi byte.
  defp parse_palette(out) do
    ~r/\]4;(\d+);rgb:([0-9a-fA-F]+)\/([0-9a-fA-F]+)\/([0-9a-fA-F]+)/
    |> Regex.scan(out)
    |> Map.new(fn [_, n, r, g, b] -> {String.to_integer(n), {hi8(r), hi8(g), hi8(b)}} end)
  end

  defp hi8(hex), do: hex |> String.pad_trailing(2, "0") |> String.slice(0, 2) |> String.to_integer(16)

  # Saturation of an RGB (0..1): how far from grey it is.
  defp saturation({r, g, b}) do
    mx = Enum.max([r, g, b])
    mn = Enum.min([r, g, b])
    if mx == 0, do: 0.0, else: (mx - mn) / mx
  end

  # A crude hue distance so the two anchors read as different colors, not two
  # near-identical shades — compares the ordering/ratios of the channels.
  defp hue_distance({r1, g1, b1}, {r2, g2, b2}) do
    abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
  end

  defp scale({r, g, b}, f), do: {round(r * f), round(g * f), round(b * f)}

  defp main_menu do
    # First run with no keys: go straight into the wizard instead of letting
    # every menu entry die with "RD_TOKEN is not set".
    unless Providers.any_configured?() and Tmdb.configured?() do
      IO.puts(:stderr, "\n  missing keys — let's set you up first")
      setup()
    end

    maybe_startup_sync()

    clear_screen()
    print_banner()
    IO.puts(:stderr, greeting())
    print_update_status()

    items =
      List.flatten([
        up_next_item(),
        {:continue, "▶ Continue — pick up where you left off"},
        {:featured, "★ Featured — trending movies, shows & anime"},
        {:watchlist, watchlist_row()},
        {:calendar, calendar_row()},
        {:search, "⌕ Search — find something by name"},
        {:settings, "⚙ Settings — toggles & preferences"}
      ])

    case pick(items, &menu_label/1, "↑↓ to move · enter to select · esc to quit", nil, nil, [], :abort) do
      :resized -> main_menu()
      nil -> quit_laev()
      {:up_next, entry} -> play_next_episode(entry)
      {:resume_last, entry} -> continue_entry(entry)
      {:continue, _} -> continue()
      {:featured, _} -> featured()
      {:watchlist, _} -> watchlist_menu()
      {:calendar, _} -> calendar()
      {:search, _} -> menu_search()
      {:settings, _} -> settings_menu()
    end
  end

  # ── settings (interactive toggles) ────────────────────────────────
  # Arrow through the settings, Enter toggles/cycles (or prompts, for text
  # values). Every change is written to the config file immediately and
  # takes effect for the rest of the session.

  @settings [
    {"LAEV_AUTOPLAY", "⚡ Autoplay next episode", {:cycle, ["off", "on"]}},
    {"LAEV_SKIP", "⏭ Intro/credits skipping", {:cycle, ["ask", "auto", "off"]}},
    {"LAEV_POSTERS", "🖼 Poster previews", {:cycle, ["auto", "ascii", "ascii-bg", "off"]}},
    {"LAEV_LANG", "🗣 Audio language preference", :text},
    {"LAEV_SUBS", "💬 Subtitle language (off = none)", :text},
    {"LAEV_DOWNLOAD_DIR", "📁 Download folder", :text},
    {"LAEV_MPV_ARGS", "🎬 Extra mpv arguments", :text}
  ]

  defp settings_menu(selected \\ 0) do
    clear_screen()

    sync_status = if Laev.Sync.enabled?(), do: "on", else: "local only"

    items =
      Enum.map(@settings, fn {key, label, kind} -> {:setting, key, label, kind} end) ++
        [
          {:sync, nil, "🔄 Cross-device sync — watchlist & progress  [#{sync_status}]", nil},
          {:integrations, nil, "🔌 Integrations — optional API keys & services", nil},
          {:keys, nil, "🔑 Core keys (RD / TorBox / TMDB) — rerun setup wizard", nil}
        ]

    case pick(items, &describe_setting/1, "enter toggles or edits · esc goes back", nil, selected) do
      nil ->
        main_menu()

      {:sync, _, _, _} = item ->
        sync_menu()
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)

      {:integrations, _, _, _} = item ->
        integrations_menu()
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)

      {:keys, _, _, _} = item ->
        setup()
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)

      {:setting, key, label, kind} = item ->
        change_setting(key, label, kind)
        settings_menu(Enum.find_index(items, &(&1 == item)) || 0)
    end
  end

  # ── integrations (optional API keys & services) ──────────────────

  # Text-key providers: {id, label, blurb, [{ENV_KEY, prompt}]}. MAL is
  # special (OAuth) and handled on its own.
  @integrations [
    {:mal, "🌸 MyAnimeList", "anime scrobbling, ratings & page links"},
    {:opensubs, "💬 OpenSubtitles", "external subtitles fallback",
     [
       {"OPENSUBTITLES_API_KEY", "API key"},
       {"OPENSUBTITLES_USERNAME", "username (for downloads)"},
       {"OPENSUBTITLES_PASSWORD", "password (for downloads)"}
     ]},
    {:jimaku, "🇯🇵 Jimaku", "anime subtitles", [{"JIMAKU_API_KEY", "API key"}]},
    {:jackett, "🔎 Jackett / Prowlarr", "extra torrent indexers",
     [
       {"JACKETT_URL", "URL (e.g. http://localhost:9117)"},
       {"JACKETT_API_KEY", "API key"},
       {"JACKETT_INDEXER", "indexer id (optional; blank = all)"}
     ]}
  ]

  defp integrations_menu(selected \\ 0) do
    clear_screen()

    case pick(@integrations, &describe_integration/1, "configure an integration · esc goes back", nil, selected) do
      nil ->
        :ok

      {:mal, _, _} = item ->
        mal_integration_menu()
        integrations_menu(Enum.find_index(@integrations, &(&1 == item)) || 0)

      {_id, _label, _blurb, keys} = item ->
        configure_keys(keys)
        integrations_menu(Enum.find_index(@integrations, &(&1 == item)) || 0)
    end
  end

  defp describe_integration({:mal, label, blurb}) do
    status =
      cond do
        not Laev.MAL.configured?() -> "needs MAL_CLIENT_ID"
        Laev.MAL.authenticated?() -> "linked ✓"
        true -> "not linked"
      end

    "#{String.pad_trailing(label, 20)} #{String.pad_trailing(blurb, 40)} [#{status}]"
  end

  defp describe_integration({_id, label, blurb, keys}) do
    set = Enum.count(keys, fn {k, _} -> configured_key?(k) end)
    status = if set > 0, do: "#{set}/#{length(keys)} set", else: "not set"
    "#{String.pad_trailing(label, 20)} #{String.pad_trailing(blurb, 40)} [#{status}]"
  end

  defp configured_key?(env_key) do
    app_key = Map.fetch!(Config.keys(), env_key)
    Application.get_env(:laev_app, app_key) not in [nil, ""]
  end

  # Prompt for each key in turn (current value shown masked, enter keeps),
  # writing straight to the config file — no hand-editing needed.
  defp configure_keys(keys) do
    for {env_key, prompt} <- keys do
      current = Application.get_env(:laev_app, Map.fetch!(Config.keys(), env_key))
      hint = if current in [nil, ""], do: "", else: " [#{mask(current)}]"

      case IO.gets("  #{prompt}#{hint} — enter to keep, or type a value: ") do
        line when is_binary(line) ->
          case String.trim(line) do
            "" -> :ok
            value -> save_setting(env_key, value)
          end

        _ ->
          :ok
      end
    end

    IO.puts(:stderr, IO.ANSI.format([:green, "  ✓ saved\n", :reset]))
  end

  defp mal_integration_menu do
    clear_screen()

    IO.puts(:stderr, IO.ANSI.format(["\n  🌸 ", :bright, "MyAnimeList", :reset, "\n"]))

    actions =
      cond do
        not Laev.MAL.configured?() ->
          IO.puts(:stderr, "  Not configured. Set the app Client ID (create one at\n" <>
            "  https://myanimelist.net/apiconfig, redirect http://localhost:8723/callback):\n")
          [{:set_id, "set MAL_CLIENT_ID"}, {:set_secret, "set MAL_CLIENT_SECRET (optional)"}]

        Laev.MAL.authenticated?() ->
          IO.puts(:stderr, "  Linked as #{Laev.MAL.username() || "?"}.\n")
          [
            {:scrobble, "⚡ auto-scrobble progress  [#{if Config.mal_scrobble?(), do: "on", else: "off"}]"},
            {:logout, "unlink MyAnimeList"},
            {:set_id, "change MAL_CLIENT_ID"}
          ]

        true ->
          IO.puts(:stderr, "  Client ID is set but not linked.\n")
          [{:login, "log in (opens browser)"}, {:set_id, "change MAL_CLIENT_ID"}]
      end

    case pick(actions, &elem(&1, 1), "enter selects · esc goes back") do
      nil ->
        :ok

      {:set_id, _} ->
        prompt_and_save("MAL_CLIENT_ID", "MAL Client ID")
        mal_integration_menu()

      {:set_secret, _} ->
        prompt_and_save("MAL_CLIENT_SECRET", "MAL Client Secret")
        mal_integration_menu()

      {:login, _} ->
        mal(["login"])
        mal_integration_menu()

      {:logout, _} ->
        Laev.MAL.logout()
        IO.puts(:stderr, "  unlinked.")
        mal_integration_menu()

      {:scrobble, _} ->
        save_setting("LAEV_MAL_SCROBBLE", if(Config.mal_scrobble?(), do: "off", else: "on"))
        mal_integration_menu()
    end
  end

  # ── cross-device sync ─────────────────────────────────────────────

  # The maintainer-hosted sync endpoint offered as the turnkey option. When
  # set, the "hosted" choice uses it and just asks the user for their token.
  @hosted_sync_url "https://sasha.don.ee/laev"

  defp sync_menu do
    clear_screen()
    IO.puts(:stderr, IO.ANSI.format(["\n  🔄 ", :bright, "Cross-device sync", :reset, "\n"]))

    if Laev.Sync.enabled?(),
      do: sync_active_menu(),
      else: sync_chooser_menu()
  end

  # Sync is off — offer the three storage tiers, Local being the default.
  defp sync_chooser_menu do
    IO.puts(:stderr, "  Where should your watch data live?")

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        "  Watchlist, history, resume points & watched flags. Never your keys.\n",
        :reset
      ])
    )

    options = [
      {:local, "📁 Local only — keep everything on this machine  (default)"},
      {:hosted, "☁  Laev hosted server — the maintainer's endpoint"},
      {:custom, "🖥  My own server — a URL I run (full control)"}
    ]

    case pick(options, &elem(&1, 1), "enter selects · esc goes back") do
      nil ->
        :ok

      {:local, _} ->
        IO.puts(:stderr, IO.ANSI.format([:green, "  ✓ already local-only — nothing leaves this machine.\n", :reset]))

      {:hosted, _} ->
        enable_hosted_sync()

      {:custom, _} ->
        enable_custom_sync()
    end
  end

  defp enable_hosted_sync do
    case @hosted_sync_url do
      url when is_binary(url) and url != "" ->
        save_setting("LAEV_SYNC_URL", url)
        IO.puts(:stderr, "  Using the hosted server at #{url}.\n")
        configure_sync_token()
        run_sync_now()
        sync_menu()

      _ ->
        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "  The hosted server isn't available yet.\n",
            :reset,
            "  Use “My own server” to point laev at a box you run.\n"
          ])
        )
    end
  end

  defp enable_custom_sync do
    prompt_and_save("LAEV_SYNC_URL", "endpoint URL (e.g. https://myserver.example/laev)")

    if Laev.Sync.url() do
      configure_sync_token()
      run_sync_now()
    end

    sync_menu()
  end

  # Ask for the sync token, but never leave a fresh device stuck with nothing
  # to paste: offer a value (the one already configured, or a freshly generated
  # one) that the user can accept with a single enter, or override by pasting a
  # token they already use on another device.
  defp configure_sync_token do
    {suggested, source} =
      case Laev.Sync.laev_key() do
        nil -> {gen_sync_token(), :new}
        existing -> {existing, :current}
      end

    label =
      case source do
        :current -> "  Your current token (press enter to keep it):"
        :new -> "  Suggested new token (press enter to use it):"
      end

    IO.puts(:stderr, label)
    IO.puts(:stderr, IO.ANSI.format(["    ", :bright, suggested, :reset, "\n"]))

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        "  This token is your identity — the same token on another device shows\n" <>
          "  the same library. Keep it private.\n",
        :reset
      ])
    )

    chosen =
      case IO.gets("  Already have a token from another setup? paste it, or press enter: ") do
        line when is_binary(line) ->
          case String.trim(line) do
            "" -> suggested
            pasted -> pasted
          end

        _ ->
          suggested
      end

    save_setting("LAEV_SYNC_TOKEN", chosen)
  end

  # A laev key: `laev_<token>.<secret>`. The server auto-provisions any
  # well-formed laev_-prefixed token and only ever sees that first half; the
  # part after the dot stays on this machine and encrypts the API keys, so the
  # key is one string to paste but two secrets in effect.
  defp gen_sync_token do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "laev_#{token}.#{secret}"
  end

  # Sync is on — manage it.
  defp sync_active_menu do
    IO.puts(:stderr, "  Syncing to #{Laev.Sync.url()}")

    token_line =
      case Laev.Sync.laev_key() do
        nil -> "  laev key: (none)"
        t -> "  laev key: #{mask(t)}"
      end

    IO.puts(:stderr, IO.ANSI.format([:faint, token_line, :reset]))

    carried =
      if Laev.Sync.keys_enabled?(),
        do: "  Watchlist, history, resume points, watched flags — and your API keys, encrypted.\n",
        else: "  Watchlist, history, resume points & watched flags — not your keys.\n"

    IO.puts(:stderr, IO.ANSI.format([:faint, carried, :reset]))

    actions = [
      {:now, "↻ sync now — pull the latest from the server"},
      {:auto, "⚙ auto-sync on launch & after episodes  [#{if Laev.Sync.auto?(), do: "on", else: "off"}]"},
      {:live, "⚡ live-save each change (pin, watched, resume)  [#{if Laev.Sync.live?(), do: "on", else: "off"}]"},
      {:keys, "🔑 carry my API keys too, encrypted  [#{if Laev.Sync.keys_enabled?(), do: "on", else: "off"}]"},
      {:show, "👁  show my laev key (to set up another device)"},
      {:token, "paste a laev key (from another setup)"},
      {:reset, "⟳ reset key — generate a fresh one"},
      {:url, "change endpoint URL"},
      {:off, "turn off (go back to local-only)"}
    ]

    case pick(actions, &elem(&1, 1), "enter selects · esc goes back") do
      nil ->
        :ok

      {:auto, _} ->
        save_setting("LAEV_SYNC_AUTO", if(Laev.Sync.auto?(), do: "off", else: "on"))
        sync_menu()

      {:live, _} ->
        save_setting("LAEV_SYNC_LIVE", if(Laev.Sync.live?(), do: "off", else: "on"))
        sync_menu()

      {:keys, _} ->
        toggle_key_sync()
        sync_menu()

      {:show, _} ->
        show_sync_token()
        sync_menu()

      {:url, _} ->
        prompt_and_save("LAEV_SYNC_URL", "endpoint URL (e.g. https://myserver.example/laev)")
        sync_menu()

      {:token, _} ->
        prompt_and_save("LAEV_SYNC_TOKEN", "access token")
        run_sync_now()
        sync_menu()

      {:reset, _} ->
        reset_sync_token()
        sync_menu()

      {:now, _} ->
        run_sync_now()
        sync_menu()

      {:off, _} ->
        save_setting("LAEV_SYNC_URL", "")
        Application.put_env(:laev_app, :sync_url, nil)
        IO.puts(:stderr, "  local-only.")
        sync_menu()
    end
  end

  # Replace the token with a freshly generated one — the escape hatch when
  # the saved token has the wrong shape for the server (e.g. an old kala_
  # token after the laev rename) or the user wants a new identity. Local
  # state is authoritative, so the next sync simply uploads everything under
  # the new token; other devices just need the new token pasted in.
  defp reset_sync_token do
    fresh = gen_sync_token()

    IO.puts(:stderr, "\n  Your new token (other devices will need it):")
    IO.puts(:stderr, IO.ANSI.format(["    ", :bright, fresh, :reset, "\n"]))

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        "  The old token stops mattering the moment this device syncs — your\n" <>
          "  library here is the source of truth and uploads under the new token.\n",
        :reset
      ])
    )

    case IO.gets("  replace the current token? [Y/n] ") do
      line when is_binary(line) ->
        if String.trim(String.downcase(line)) in ["", "y", "yes"] do
          save_setting("LAEV_SYNC_TOKEN", fresh)
          run_sync_now()
        else
          IO.puts(:stderr, "  kept the current token.\n")
        end

      _ ->
        IO.puts(:stderr, "  kept the current token.\n")
    end
  end

  # Opting the API keys into the bundle. Turning it on is a real change in what
  # the key is worth, so say so rather than flipping a silent switch; an older
  # key with no secret half can't encrypt anything, so offer to reissue.
  defp toggle_key_sync do
    cond do
      Laev.Sync.keys_enabled?() ->
        save_setting("LAEV_SYNC_KEYS", "off")

        IO.puts(
          :stderr,
          IO.ANSI.format([
            :faint,
            "\n  This device will stop sending its keys. Whatever is already stored\n" <>
              "  stays there for your other devices — \"reset key\" clears it.\n",
            :reset
          ])
        )

        IO.gets("  press enter to continue… ")

      is_nil(Laev.Sync.secret()) ->
        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "\n  This laev key predates encrypted keys and has no secret half.\n",
            :reset,
            "  Use “reset key” to issue a new one, then turn this on.\n"
          ])
        )

        IO.gets("  press enter to continue… ")

      true ->
        IO.puts(:stderr, IO.ANSI.format(["\n  🔑 ", :bright, "Carry your API keys", :reset, "\n"]))

        IO.puts(
          :stderr,
          "  Your keys (debrid, TMDB, indexers — everything but your MyAnimeList\n" <>
            "  login) get encrypted with the half of your laev key that never leaves\n" <>
            "  this machine, so the server stores something it cannot read. A new\n" <>
            "  install that pastes the key is set up with no keys to re-enter.\n"
        )

        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "  Your laev key then unlocks your debrid account — keep it like a password,\n" <>
              "  and note that losing it means the stored copy can't be opened again.\n",
            :reset
          ])
        )

        case IO.gets("  turn it on? [y/N] ") do
          line when is_binary(line) ->
            if String.trim(String.downcase(line)) in ["y", "yes"] do
              save_setting("LAEV_SYNC_KEYS", "on")
              run_sync_now()
            else
              IO.puts(:stderr, "  left off.\n")
            end

          _ ->
            :ok
        end
    end
  end

  # Print the full key + endpoint so it can be copied to another machine.
  defp show_sync_token do
    clear_screen()
    IO.puts(:stderr, IO.ANSI.format(["\n  🔑 ", :bright, "Your laev key", :reset, "\n"]))
    IO.puts(:stderr, "  Paste this into a new install (setup asks for it, or Settings →")
    IO.puts(:stderr, "  Cross-device sync) and that machine becomes a copy of this one.\n")
    IO.puts(:stderr, IO.ANSI.format(["  endpoint  ", :bright, Laev.Sync.url() || "(none)", :reset]))
    IO.puts(:stderr, IO.ANSI.format(["  laev key  ", :bright, Laev.Sync.laev_key() || "(none)", :reset]))

    if Laev.Sync.keys_enabled?() do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          "\n  ",
          :yellow,
          "This key also unlocks your API keys — it is worth as much as the",
          :reset,
          "\n  ",
          :yellow,
          "debrid account behind it. Treat it like a password.",
          :reset
        ])
      )
    end

    IO.gets("\n  press enter to go back… ")
  end

  defp run_sync_now do
    IO.puts(:stderr, "  syncing…")

    case Laev.Sync.sync() do
      {:ok, summary} ->
        IO.puts(:stderr, IO.ANSI.format([:green, "  ✓ synced · #{Laev.Sync.url()}", :reset]))
        Enum.each(sync_summary_lines(summary), &IO.puts(:stderr, "  " <> &1))
        IO.puts(:stderr, "")

      {:error, {:http, 401, _}} ->
        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "  ✗ the server rejected this token.\n",
            :reset,
            "  Check the endpoint URL, paste a token the server accepts, or use\n" <>
              "  “reset token” to generate a fresh one.\n"
          ])
        )

      {:error, reason} ->
        IO.puts(:stderr, IO.ANSI.format([:red, "  ✗ #{inspect(reason)}\n", :reset]))

      :disabled ->
        IO.puts(:stderr, "  no endpoint set.\n")
    end

    # The caller re-renders (and clears) the menu right after, so hold the
    # result on screen until the user acknowledges it.
    IO.gets("  press enter to continue… ")
  end

  # Interactive quit: with auto-sync on, push whatever this session changed
  # (a position mid-episode, post-play toggles) before the process dies —
  # the playback watcher dies with us and can't do it after.
  defp quit_laev do
    if Laev.Sync.auto?(), do: Laev.Sync.sync_quiet("exit")
    System.halt(0)
  end

  # Startup pull-merge-push, once per session, before the menu reads state.
  # Only when the user opted into auto-sync; otherwise sync is manual.
  defp maybe_startup_sync do
    if Laev.Sync.enabled?() and Laev.Sync.auto?() and not Process.get(:laev_synced, false) do
      Process.put(:laev_synced, true)
      Laev.Sync.sync_quiet("synced")
    end
  end

  # `laev sync` — one-shot sync from the CLI; `laev sync status` shows config.
  defp sync_cmd(["status" | _]) do
    if Laev.Sync.enabled?() do
      IO.puts("sync:  on  → #{Laev.Sync.url()}")
      IO.puts("token: #{if Laev.Sync.token(), do: "set", else: "none"}")
      IO.puts("auto:  #{if Laev.Sync.auto?(), do: "on (syncs on launch & after episodes)", else: "off (manual — run `laev sync`)"}")
      IO.puts("live:  #{if Laev.Sync.live?(), do: "on (each change pushed as a delta)", else: "off"}")
    else
      IO.puts("sync:  local only (set LAEV_SYNC_URL to enable)")
    end
  end

  defp sync_cmd(_) do
    case Laev.Sync.sync() do
      {:ok, summary} ->
        IO.puts("synced · #{Laev.Sync.url()}")
        Enum.each(sync_summary_lines(summary), &IO.puts("  " <> &1))

      {:error, reason} ->
        die("sync failed: #{inspect(reason)}")

      :disabled ->
        die("sync is not configured — set LAEV_SYNC_URL (see: laev sync status)")
    end
  end

  # Human-readable per-collection lines: what's in your library and what
  # moved this sync (↓ pulled from server, ↑ pushed up).
  defp sync_summary_lines(summary) do
    labels = [watchlist: "watchlist", resume: "history", positions: "positions", tracks: "track prefs"]

    for {coll, label} <- labels do
      s = summary[coll] || %{pulled: 0, pushed: 0, total: 0, local: 0, server: 0}

      moved =
        [s.pulled > 0 && "↓#{s.pulled}", s.pushed > 0 && "↑#{s.pushed}"]
        |> Enum.filter(& &1)
        |> Enum.join(" ")

      moved = if moved == "", do: "up to date", else: moved

      "#{String.pad_trailing(label, 12)} #{String.pad_leading("#{s.total}", 4)} items  " <>
        "(local #{s.local} · server #{s.server})   #{moved}"
    end
  end

  defp prompt_and_save(env_key, label) do
    case IO.gets("  #{label}: ") do
      line when is_binary(line) ->
        case String.trim(line) do
          "" -> :ok
          value -> save_setting(env_key, value)
        end

      _ ->
        :ok
    end
  end

  defp describe_setting({:keys, _, label, _}), do: label
  defp describe_setting({:sync, _, label, _}), do: label
  defp describe_setting({:integrations, _, label, _}), do: label

  defp describe_setting({:setting, key, label, _kind}),
    do: "#{String.pad_trailing(label, 34)}  [#{setting_value(key)}]"

  defp setting_value("LAEV_AUTOPLAY"), do: if(Config.autoplay?(), do: "on", else: "off")
  defp setting_value("LAEV_SKIP"), do: Config.skip()
  defp setting_value("LAEV_POSTERS"), do: Config.posters()
  defp setting_value("LAEV_LANG"), do: Config.lang()
  defp setting_value("LAEV_SUBS"), do: Config.subs_lang() || "off"

  defp setting_value("LAEV_DOWNLOAD_DIR"),
    do: Application.get_env(:laev_app, :download_dir) || Path.join(System.user_home!(), "Videos")

  defp setting_value("LAEV_MPV_ARGS"),
    do: Application.get_env(:laev_app, :mpv_args) || "(none)"

  defp change_setting(key, _label, {:cycle, values}) do
    current = setting_value(key)
    index = Enum.find_index(values, &(&1 == current)) || 0
    next = Enum.at(values, rem(index + 1, length(values)))
    save_setting(key, next)
  end

  defp change_setting(key, label, :text) do
    case IO.gets("  #{label} [#{setting_value(key)}] — new value (enter keeps): ") do
      :eof ->
        :ok

      line ->
        case String.trim(line) do
          "" -> :ok
          value -> save_setting(key, value)
        end
    end
  end

  defp save_setting(key, value) do
    write_config_keys([{key, value}])
    # Env vars beat the file, so a shell-exported key won't budge — put the
    # new value straight into the app env so the change applies either way.
    Application.put_env(:laev_app, Map.fetch!(Config.keys(), key), value)
  end

  # The smart first row: if the most recent thing was an episode watched to
  # the end, offer its next episode; if it was left mid-way, offer to resume
  # it directly. Falls back to nothing (the plain menu) otherwise.
  defp up_next_item do
    case Laev.Resume.all() do
      [entry | _] ->
        ctx = entry_ctx(entry)

        cond do
          Laev.Position.finished?(ctx) and is_integer(entry["episode"]) ->
            [{:up_next, %{entry | "episode" => entry["episode"] + 1}}]

          Laev.Position.resume_at(ctx) != nil ->
            [{:resume_last, entry}]

          true ->
            []
        end

      _ ->
        []
    end
  end

  defp menu_label({:up_next, entry}),
    do: "⚡ Up Next — #{entry["title"]}#{entry_ep(entry)}"

  defp menu_label({:resume_last, entry}) do
    at =
      case Laev.Position.resume_at(entry_ctx(entry)) do
        nil -> ""
        time -> " · at #{time}"
      end

    "▶ Resume — #{entry["title"]}#{entry_ep(entry)}#{at}"
  end

  defp menu_label({_action, label}) when is_binary(label), do: label

  defp entry_ep(entry) do
    cond do
      entry["season"] && entry["episode"] -> " S#{pad2(entry["season"])}E#{pad2(entry["episode"])}"
      entry["episode"] -> " · Ep #{entry["episode"]}"
      true -> ""
    end
  end

  # ── calendar (release dates for the watchlist) ────────────────────

  defp calendar do
    unless Tmdb.configured?() do
      die("the calendar needs TMDB_API_KEY — run: laev setup")
    end

    if Laev.Watchlist.count() == 0 do
      IO.puts(:stderr, "\n  the calendar shows your watchlist — pin titles with ctrl-s first")
      if tty?(), do: main_menu(), else: System.halt(0)
    end

    IO.puts(:stderr, "checking release schedules…")
    events = Laev.Calendar.events()
    calendar_screen(events, 0)
  end

  defp calendar_screen(events, initial) do
    clear_screen()
    print_month_grid(events)

    if events == [] do
      IO.puts(:stderr, "  nothing scheduled in the next weeks for your pinned titles\n")
      if tty?(), do: main_menu(), else: System.halt(0)
    else
      result =
        pick(
          events,
          &describe_event/1,
          "⧉ enter watches · ctrl-r refreshes · ctrl-o info · esc backs out",
          nil,
          initial,
          ["ctrl-r", "ctrl-o"],
          :abort
        )

      case result do
        :resized ->
          calendar_screen(events, initial)

        nil ->
          main_menu()

        {"ctrl-o", event} ->
          open_media_page(event["type"], event["tmdb_id"], event["title"])
          calendar_screen(events, Enum.find_index(events, &(&1 == event)) || 0)

        {"ctrl-r", _} ->
          File.rm_rf(Path.join(System.tmp_dir!(), "laev-calendar"))
          IO.puts(:stderr, "refreshing schedules…")
          calendar_screen(Laev.Calendar.events(), 0)

        {nil, event} ->
          open_event(events, event)
      end
    end
  end

  defp open_event(events, %{"date" => nil} = event) do
    # "waiting" entries: no date, but enter still drops into the watch flow
    # (a leaked WEB or a good source may exist before the official date).
    _ = events
    play_title(%{type: event["type"], id: event["tmdb_id"], title: event["title"], year: nil})
  end

  defp open_event(events, event) do
    date = Date.from_iso8601!(event["date"])

    if Date.compare(date, Date.utc_today()) == :gt do
      IO.puts(:stderr, "  not out yet — #{event["date"]}#{days_until(event["date"])}")
      Process.sleep(1200)
      calendar_screen(events, Enum.find_index(events, &(&1 == event)) || 0)
    else
      case event["kind"] do
        "episode" ->
          entry = %{
            "type" => "tv",
            "tmdb_id" => event["tmdb_id"],
            "title" => event["title"],
            "season" => event["season"],
            "episode" => event["episode"],
            "anime" => event["anime"] || false,
            "search_title" => event["search_title"]
          }

          play_entry(entry, rd_opts(event["season"], event["episode"]))

        _movie_release ->
          play_title(%{type: "movie", id: event["tmdb_id"], title: event["title"], year: nil})
      end
    end
  end

  # Responsive: a wall-calendar with event titles inside the day cells when
  # the terminal is wide enough; the compact grid + agenda otherwise.
  defp print_month_grid(events) do
    {_rows, cols} = tty_size()
    if cols >= 120, do: print_big_grid(events, cols), else: print_small_grid(events)
  end

  defp print_big_grid(events, cols) do
    today = Date.utc_today()
    cell = min(26, div(cols - 9, 7))

    by_day =
      events
      |> Enum.reject(&is_nil(&1["date"]))
      |> Enum.map(&{Date.from_iso8601!(&1["date"]), &1})
      |> Enum.filter(fn {d, _} -> d.month == today.month and d.year == today.year end)
      |> Enum.group_by(fn {d, _} -> d.day end, fn {d, ev} ->
        {short_event(ev), Date.compare(d, today) != :gt}
      end)

    first = Date.beginning_of_month(today)
    offset = Date.day_of_week(first) - 1

    weeks =
      (List.duplicate(nil, offset) ++ Enum.to_list(1..Date.days_in_month(today)))
      |> Enum.chunk_every(7, 7, List.duplicate(nil, 6))

    month_name = Elixir.Calendar.strftime(today, "%B %Y")
    width = cell * 7 + 6
    IO.puts(:stderr, IO.ANSI.format(["\n", :bright, String.pad_leading(month_name, div(width + String.length(month_name), 2)), :reset]))

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        Enum.map_join(~w(Mon Tue Wed Thu Fri Sat Sun), " ", &String.pad_trailing(&1, cell)),
        :reset
      ])
    )

    sep = IO.ANSI.format([:faint, String.duplicate("─", width), :reset]) |> IO.iodata_to_binary()

    # Uniform slot height for every week — the busiest day sets it (cap 3),
    # empty weeks still get the same padding so the grid rows line up.
    height =
      by_day
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 1 end)
      |> min(3)
      |> max(1)

    for week <- weeks do
      IO.puts(:stderr, sep)

      day_line =
        Enum.map_join(week, " ", fn
          nil ->
            String.duplicate(" ", cell)

          day ->
            text = String.pad_trailing(String.pad_leading("#{day}", 2), cell)

            cond do
              day == today.day ->
                IO.iodata_to_binary(IO.ANSI.format_fragment([:inverse, text, :inverse_off]))

              Map.has_key?(by_day, day) ->
                IO.iodata_to_binary(IO.ANSI.format_fragment([:yellow, :bright, text, :reset]))

              true ->
                IO.iodata_to_binary(IO.ANSI.format_fragment([:faint, text, :reset]))
            end
        end)

      IO.puts(:stderr, day_line)

      for i <- 0..(height - 1)//1 do
        line =
          Enum.map_join(week, " ", fn day ->
            today? = day == today.day

            case day && Enum.at(Map.get(by_day, day, []), i) do
              nil ->
                blank = String.duplicate(" ", cell)

                if today?,
                  do: IO.iodata_to_binary(IO.ANSI.format_fragment([:inverse, blank, :inverse_off])),
                  else: blank

              {label, out?} ->
                text = String.pad_trailing(truncate("· " <> label, cell - 1), cell)
                color = if out?, do: :green, else: :yellow
                style = if today?, do: [:inverse, color], else: [color]
                IO.iodata_to_binary(IO.ANSI.format_fragment(style ++ [text, :reset, :inverse_off]))
            end
          end)

        IO.puts(:stderr, line)
      end
    end

    IO.puts(:stderr, sep <> "\n")
  end

  defp short_event(ev) do
    case ev["kind"] do
      "episode" ->
        se = if ev["season"], do: "S#{ev["season"]}E#{ev["episode"]}", else: "E#{ev["episode"]}"
        "#{ev["title"]} #{se}"

      "digital" ->
        "#{ev["title"]} · digital"

      _ ->
        "#{ev["title"]} · theater"
    end
  end

  # The current month as a grid: today reversed, drop days in marquee gold.
  defp print_small_grid(events) do
    today = Date.utc_today()

    drop_days =
      events
      |> Enum.reject(&is_nil(&1["date"]))
      |> Enum.map(&Date.from_iso8601!(&1["date"]))
      |> Enum.filter(&(&1.month == today.month and &1.year == today.year))
      |> MapSet.new(& &1.day)

    month_name = Elixir.Calendar.strftime(today, "%B %Y")
    first = Date.beginning_of_month(today)
    offset = Date.day_of_week(first) - 1

    cells =
      List.duplicate("  ", offset) ++
        for day <- 1..Date.days_in_month(today) do
          text = String.pad_leading("#{day}", 2)

          cond do
            day == today.day ->
              IO.ANSI.format_fragment([:inverse, text, :inverse_off]) |> IO.iodata_to_binary()

            MapSet.member?(drop_days, day) ->
              IO.ANSI.format_fragment([:yellow, :bright, text, :reset]) |> IO.iodata_to_binary()

            true ->
              IO.ANSI.format_fragment([:faint, text, :reset]) |> IO.iodata_to_binary()
          end
        end

    IO.puts(:stderr, IO.ANSI.format(["\n  ", :bright, String.pad_leading(month_name, 14), :reset]))
    IO.puts(:stderr, IO.ANSI.format([:faint, "  Mo Tu We Th Fr Sa Su", :reset]))

    cells
    |> Enum.chunk_every(7)
    |> Enum.each(fn week -> IO.puts(:stderr, "  " <> Enum.join(week, " ")) end)

    IO.puts(:stderr, "")
  end

  # Agenda rows carry the weekday and a color-coded status (needs --ansi):
  #   Thu Sep 03 · Silo S03E10 · tomorrow      (yellow countdown)
  #   Sun Aug 30 · Lanterns S01E03 · out ▶     (green — watchable now)
  #   waiting    · Mutiny — digital TBA        (faint)
  defp describe_event(%{"date" => nil} = event) do
    IO.iodata_to_binary(IO.ANSI.format([:faint, "waiting    · #{event["label"]}", :reset]))
  end

  defp describe_event(event) do
    date = Date.from_iso8601!(event["date"])
    day = Elixir.Calendar.strftime(date, "%a %b %d")

    line =
      case Date.compare(date, Date.utc_today()) do
        :gt -> [day, " · ", event["label"], :yellow, days_until(event["date"]), :reset]
        :eq -> [day, " · ", event["label"], :green, :bright, " · today!", :reset]
        :lt -> [day, " · ", event["label"], :green, " · out ▶", :reset]
      end

    IO.iodata_to_binary(IO.ANSI.format(line))
  end

  defp calendar_row do
    case length(Laev.Calendar.cached_events()) do
      0 -> "⧉ Calendar — when your watchlist drops"
      1 -> "⧉ Calendar — 1 drop this week"
      n -> "⧉ Calendar — #{n} drops this week"
    end
  rescue
    _ -> "⧉ Calendar — when your watchlist drops"
  end

  defp watchlist_row do
    case Laev.Watchlist.count() do
      0 -> "≡ Watchlist — empty (ctrl-s on any title pins it)"
      n -> "≡ Watchlist — #{n} saved"
    end
  end

  # In-progress first (most recent), then fresh pins, watched movies last.
  defp watchlist_menu(initial \\ 0) do
    clear_screen()
    entries = Laev.Watchlist.all() |> Enum.sort_by(&watchlist_rank/1)

    if entries == [] do
      IO.puts(:stderr, "\n  watchlist is empty — hover any title and press ctrl-s to pin it")
      main_menu()
    else
      result =
        pick(
          entries,
          &describe_watchlist/1,
          "≡ watchlist · enter watches · ctrl-d removes · ctrl-o info",
          & &1["poster"],
          initial,
          ["ctrl-d", "ctrl-o"]
        )

      case result do
        nil ->
          main_menu()

        {"ctrl-o", entry} ->
          open_media_page(entry["type"], entry["tmdb_id"], entry["title"])
          watchlist_menu(Enum.find_index(entries, &(&1 == entry)) || 0)

        {"ctrl-d", entry} ->
          Laev.Watchlist.remove(entry["type"], entry["tmdb_id"])
          Laev.Sync.live_push()
          index = Enum.find_index(entries, &(&1 == entry)) || 1
          watchlist_menu(max(index - 1, 0))

        {nil, entry} ->
          play_title(%{
            type: entry["type"],
            id: entry["tmdb_id"],
            title: entry["title"],
            year: entry["year"]
          })
      end
    end
  end

  defp watchlist_rank(entry) do
    resume = Laev.Resume.get(entry["type"], entry["tmdb_id"])

    cond do
      watched_movie?(entry) -> {2, 0}
      resume -> {0, -(resume["updated_at"] || 0)}
      true -> {1, -(entry["added_at"] || 0)}
    end
  end

  defp watched_movie?(entry) do
    entry["type"] == "movie" and
      Laev.Position.finished?(%{
        type: "movie",
        tmdb_id: entry["tmdb_id"],
        season: nil,
        episode: nil
      })
  end

  defp describe_watchlist(entry) do
    kind = if entry["type"] == "tv", do: "series", else: "movie"

    progress =
      case Laev.Resume.get(entry["type"], entry["tmdb_id"]) do
        nil ->
          ""

        resume ->
          at = Laev.Position.resume_at(entry_ctx(resume))
          entry_ep(resume) <> if(at, do: " · at #{at}", else: "")
      end

    mark = if watched_movie?(entry), do: "✓ ", else: ""
    "#{mark}#{entry["title"]} (#{entry["year"] || "?"}) · #{kind}#{progress}"
  end

  defp play_next_episode(entry) do
    IO.puts(:stderr, "#{entry["title"]}#{entry_ep(entry)} — finding sources…")
    play_entry(entry, rd_opts(entry["season"], entry["episode"]))
  end

  # Version line under the greeting. Capped at 2s and silent on any failure
  # so the menu never waits on GitHub; the result is cached between launches.
  defp print_update_status do
    task = Task.async(fn -> Laev.UpdateCheck.status() end)

    case Task.yield(task, 2000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:current, version}} ->
        IO.puts(:stderr, IO.ANSI.format([:faint, "  v#{version} — up to date\n", :reset]))

      {:ok, {:update, current, latest}} ->
        IO.puts(
          :stderr,
          IO.ANSI.format([
            :yellow,
            "  ⬆ v#{current} → v#{latest} available: ",
            :reset,
            "https://github.com/alexdont/laev/releases/latest\n"
          ])
        )

      _ ->
        :ok
    end
  end

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @adjectives ~w(beautiful lovely wonderful cozy splendid fine quiet)

  defp greeting do
    user = System.get_env("USER") || System.get_env("USERNAME") || "you"
    {date, {hour, minute, _}} = :calendar.local_time()

    hello =
      cond do
        hour < 5 -> "Good Night"
        hour < 12 -> "Good Morning"
        hour < 17 -> "Good Afternoon"
        hour < 22 -> "Good Evening"
        true -> "Good Night"
      end

    {h12, ampm} = if hour >= 12, do: {hour - 12, "PM"}, else: {hour, "AM"}
    h12 = if h12 == 0, do: 12, else: h12
    day = Enum.at(@weekdays, :calendar.day_of_the_week(date) - 1)

    IO.ANSI.format([
      "\n  🍿 ",
      :bright,
      hello,
      :reset,
      ", ",
      :bright,
      :cyan,
      user,
      :reset,
      ".\n     It's ",
      :yellow,
      "#{h12}:#{pad2(minute)} #{ampm}",
      :reset,
      " on a ",
      :magenta,
      Enum.random(@adjectives),
      :reset,
      " ",
      :green,
      day,
      :reset,
      "!\n"
    ])
  end

  # How many past searches to keep (and show).
  @search_history_max 100

  defp menu_search do
    if System.find_executable("fzf"), do: menu_search_fzf(), else: menu_search_plain()
  end

  defp menu_search_plain do
    case IO.gets("search for: ") do
      :eof ->
        back()

      line ->
        case String.trim(line) do
          "" -> back()
          query -> watch([query])
        end
    end
  end

  # The search prompt, with the last searches listed under it, newest first.
  # Typing narrows the list; ↑↓ then walk what's left, each step highlighting a
  # row *and* putting it in the bar — so typing a few letters and pressing ↓
  # completes to the full title, which can still be edited before enter runs it
  # (a typo stays in the list: walk to it, fix it, and both versions are kept).
  # ↑ past the top clears the bar and restores the full list.
  #
  # The catch is that the bar is also fzf's filter, so filling it from the list
  # would re-filter by the full title and drop the sibling matches. Starting the
  # walk therefore turns the search off (`disable-search`), which freezes the
  # matches as they are and leaves the bar as a plain text field; editing the
  # bar, or ↑ back past the top, turns it on again. The alternatives are all
  # worse: search() keeps the list but strands the highlight, and re-syncing
  # the highlight with pos() races fzf's asynchronous search.
  defp menu_search_fzf do
    hist = search_history_path()
    prune_search_history(hist)

    header = "type to narrow · ↑↓ recalls (edit it, or enter to run it) · ctrl-d forgets · esc backs out"

    # fzf always parks its cursor on a row, so "nothing selected yet" is drawn
    # by hiding the pointer (--pointer=) and neutralising the current-line
    # colors: until ↓ is pressed the list is just a list. The pointer doubles
    # as the "is a walk in progress" flag — empty means not walking, so the
    # first ↓ takes the top row instead of stepping past it, and that holds
    # even if something was typed first. With nothing matching what was typed
    # there is nothing to walk to, so ↓ leaves the bar alone.
    down =
      ~s[test "$FZF_MATCH_COUNT" -gt 0 || exit; ] <>
        ~s[test -n "$FZF_POINTER" && echo "down+replace-query" ] <>
        ~s[|| echo "disable-search+replace-query+change-pointer(▌)"]

    up =
      ~s[test "$FZF_POS" -le 1 && echo "enable-search+clear-query+change-pointer()" ] <>
        ~s[|| echo "up+replace-query"]

    # Editing a recalled title has to start filtering again, but the walk edits
    # the bar too, so the two are told apart by what the bar holds: a walk step
    # leaves it exactly equal to the row it just took, while typing or deleting
    # makes it differ. Any such edit drops back to "nothing selected", with the
    # list narrowed to the new text, so the next ↓ walks those matches instead
    # of the frozen ones.
    change = ~s[test "$FZF_QUERY" = "$FZF_CURRENT_ITEM" || echo "enable-search+change-pointer()"]

    # No --history: laev owns this file, so ctrl-d can edit it in place (with
    # --history fzf rewrites the file from its own in-memory copy on exit and
    # silently resurrects whatever was deleted). The path reaches fzf's own
    # bind shell as an env var — the outer sh's positional args don't exist
    # there.
    fzf =
      ~s(fzf --print-query --tac --no-multi --reverse --height=~60% ) <>
        ~s(--pointer= --color=current-fg:-1,current-bg:-1,current-hl:-1 ) <>
        ~s(--prompt='search for: ' --header="$2" ) <>
        ~s[--bind 'down:transform:#{down}' ] <>
        ~s[--bind 'up:transform:#{up}' ] <>
        ~s[--bind 'change:transform:#{change}' ] <>
        ~s[--bind 'ctrl-d:execute-silent(grep -vxF -- {} "$LAEV_HIST" > "$LAEV_HIST.tmp"; ] <>
        ~s[mv "$LAEV_HIST.tmp" "$LAEV_HIST")+reload(cat "$LAEV_HIST")' ] <>
        ~s(< "$1")

    result = System.cmd("sh", ["-c", fzf, "sh", hist, header], env: [{"LAEV_HIST", hist}])

    case result do
      # 0 and 1 both mean the prompt was accepted (1 = the list was empty or
      # nothing matched). Anything else is esc/ctrl-c.
      {out, code} when code in [0, 1] ->
        case String.trim(search_choice(out)) do
          "" ->
            back()

          query ->
            remember_search(hist, query)
            watch([query])
        end

      _ ->
        back()
    end
  end

  # Move a search to the top of the list (newest), whether it's new or one
  # that was picked out of the list again, and hold the file at its cap.
  defp remember_search(path, query) do
    kept = path |> search_history_lines() |> Enum.reject(&(&1 == query))

    write_search_history(path, Enum.take(kept ++ [query], -@search_history_max))
  rescue
    _ -> :ok
  end

  # --print-query prints the bar first, then the highlighted row. Only the bar
  # counts: it is what the user is looking at and editing, walking the list
  # fills it, and with search disabled the highlighted row is unrelated to
  # freshly typed text. An empty bar therefore means nothing was picked — no
  # walk, nothing typed — which is why enter on an untouched prompt backs out
  # rather than quietly running whatever fzf happened to park its cursor on.
  defp search_choice(out), do: out |> String.split("\n", parts: 2) |> hd()

  defp search_history_path do
    dir = Application.get_env(:laev_app, :data_dir) || Path.join(System.user_home!(), ".laev")
    Path.join(dir, "search_history")
  end

  # Collapse repeats (keeping each query's most recent position) and cap the
  # file, so the list doesn't fill with the same title typed five times. Also
  # guarantees the file exists — fzf reads it as its list.
  defp prune_search_history(path) do
    entries = search_history_lines(path)

    pruned =
      entries
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.take(@search_history_max)
      |> Enum.reverse()

    if pruned != entries or not File.exists?(path), do: write_search_history(path, pruned)
    :ok
  end

  defp search_history_lines(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  defp write_search_history(path, lines) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Enum.map_join(lines, "", &(&1 <> "\n")))
  rescue
    _ -> :ok
  end

  # True when stdout is a terminal (a human), false when piped (a frontend).
  defp tty?, do: IO.ANSI.enabled?()

  # Esc backs out to the main menu everywhere (piped/scripted runs exit).
  defp back do
    if tty?(), do: main_menu(), else: System.halt(0)
  end

  # Full-screen feel (mov-cli style): each menu screen replaces what came
  # before instead of stacking under the log noise. Wipes the visible screen
  # and the scrollback, then homes the cursor. Only ever called on a tty.
  defp clear_screen, do: IO.write(:stderr, "\e[2J\e[3J\e[H")

  # ── search ────────────────────────────────────────────────────────

  defp search(argv) do
    {opts, query} = search_args(argv, "search")
    sources = run_search(query, opts)

    pretty? = opts[:pretty] || (tty?() and !opts[:json])

    if pretty? do
      print_sources(sources)
      IO.puts(:stderr, ~s(\nto pick one and play it: laev watch "#{query}"))
    else
      IO.puts(Jason.encode!(sources))
    end
  end

  defp search_args(argv, cmd) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [backend: :string, limit: :integer, pretty: :boolean, json: :boolean]
      )

    check_invalid(invalid)
    query = Enum.join(args, " ")
    if query == "", do: die(~s(#{cmd} needs a query: laev #{cmd} "the matrix"))
    {opts, query}
  end

  defp run_search(query, opts) do
    backend =
      Map.get(@backends, opts[:backend] || "apibay") ||
        die("unknown backend: #{opts[:backend]} (apibay | nyaa | anime)")

    case Sources.search(query, backend: backend) do
      {:ok, sources} ->
        if opts[:limit], do: Enum.take(sources, opts[:limit]), else: sources

      {:error, reason} ->
        die("search failed: #{inspect(reason)}")
    end
  end

  defp print_sources([]), do: IO.puts("no sources found")

  defp print_sources(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.each(fn {s, i} ->
      IO.puts(String.pad_leading("#{i}", 3) <> ". " <> describe(s))
    end)
  end

  # ── watch (interactive) ───────────────────────────────────────────

  defp watch(argv), do: run_watch(argv)

  # Same flow as watch, but the chosen stream is saved to disk instead of
  # played. The mode is read at the single point where playback happens
  # (finish_play/4), so the whole title/source pipeline is shared.
  defp download(argv) do
    Process.put(:laev_mode, :download)
    run_watch(argv)
  end

  defp run_watch(argv) do
    {opts, query} = watch_args(argv)

    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: laev setup")
    end

    if opts[:auto], do: Process.put(:laev_auto, true)
    if opts[:binge], do: Process.put(:laev_binge, true)

    cond do
      opts[:raw] ->
        watch_raw(query, opts)

      not Tmdb.configured?() ->
        IO.puts(:stderr, "TMDB_API_KEY not set — falling back to raw torrent search")
        watch_raw(query, opts)

      true ->
        watch_title(query)
    end
  end

  defp watch_args(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [backend: :string, limit: :integer, raw: :boolean, auto: :boolean, binge: :boolean]
      )

    check_invalid(invalid)
    query = Enum.join(args, " ")
    if query == "", do: die(~s(watch needs a query: laev watch "the matrix"))
    {opts, query}
  end

  defp watch_raw(query, opts) do
    case run_search(query, opts) do
      [] -> die("no sources found for \"#{query}\"")
      sources -> probe_and_pick(sources, [], nil)
    end
  end

  # The title-first flow: TMDB titles → (season → episode for TV) → sources.
  defp watch_title(query) do
    # A trailing year ("in the gray 2026") kills TMDB's text match — strip it
    # and use it to rank instead (soft, ±1: release dates shift).
    {q, year} = split_year(query)
    title = pick_title(q, year, 1, []) || back()
    play_title(title)
  end

  # Everything downstream of "which title": details → (episodes) → sources.
  defp play_title(title) do
    details =
      case fetch_details(title) do
        {:ok, details} -> details
        {:error, reason} -> die(tmdb_error(reason, "lookup"))
      end

    if anime?(details) do
      play_anime(title, details)
    else
      play_standard(title, details)
    end
  end

  # The one play-context builder — every play path goes through this (or
  # entry_ctx/1 for resume entries) so the shape can't drift between them.
  defp build_ctx(type, tmdb_id, title, opts) do
    %{
      type: type,
      tmdb_id: tmdb_id,
      title: title,
      season: opts[:season],
      episode: opts[:episode],
      poster_path: opts[:poster_path],
      anime: opts[:anime] || false,
      search_title: opts[:search_title]
    }
  end

  defp entry_ctx(entry) do
    build_ctx(entry["type"], entry["tmdb_id"], entry["title"],
      season: entry["season"],
      episode: entry["episode"],
      poster_path: entry["poster_path"],
      anime: entry["anime"] || false,
      search_title: entry["search_title"]
    )
  end

  defp play_standard(title, details) do
    imdb = Tmdb.imdb_id(details)

    {season, episode} =
      case title.type do
        "movie" -> {nil, nil}
        "tv" -> pick_episode(details, title[:season])
      end

    ctx =
      build_ctx(title.type, title.id, title.title,
        season: season,
        episode: episode,
        poster_path: details["poster_path"]
      )

    title.type
    |> title_sources(title.title, title.year, imdb, season, episode)
    |> probe_and_pick(rd_opts(season, episode), ctx)
  end

  # ── anime ─────────────────────────────────────────────────────────
  # Anime lives on different trackers (Nyaa/AnimeTosho), uses absolute episode
  # numbers (no seasons), and matches best by AniDB id — so route it through
  # Kitsu instead of the live-action season/episode flow.

  defp anime?(%{"original_language" => "ja", "genres" => genres}) when is_list(genres),
    do: Enum.any?(genres, &(&1["id"] == 16))

  defp anime?(_details), do: false

  defp play_anime(title, details) do
    IO.puts(:stderr, "anime — matching on Kitsu for episode list + AniDB id…")
    kitsu = kitsu_pick(title.title)
    search_title = (kitsu.anime && kitsu.anime.title) || title.title

    case {title.type, kitsu.episodes} do
      {"movie", _} ->
        ctx = anime_ctx(title, details, nil, search_title)
        q = Sources.anime_movie_query(search_title)

        case Sources.search(q, backend: :anime) do
          {:ok, sources} ->
            tor = case Sources.torrentio_anime_movie(kitsu.kitsu_id) do
              {:ok, list} -> list
              _ -> []
            end

            with_library(q, tor ++ sources) |> probe_and_pick([], ctx)

          {:error, reason} ->
            die("anime source search failed: #{inspect(reason)}")
        end

      {"tv", []} ->
        # Not on Kitsu (or no episodes listed) — the live-action flow still
        # works via Torrentio's IMDb-id lookup.
        IO.puts(:stderr, "not matched on Kitsu — falling back to the standard flow")
        play_standard(title, details)

      {"tv", episodes} ->
        episodes = enrich_episodes(episodes, Kitsu.episode_details(kitsu.anime))

        ctx_of = fn ep -> %{type: "tv", tmdb_id: title.id, season: nil, episode: ep.number} end
        rt_of = fn ep -> runtime_seconds(Map.get(ep, :runtime)) end
        describe = fn ep -> watched_label(ctx_of.(ep), describe_anime_episode(ep), rt_of.(ep)) end

        episode =
          pick_episodes(episodes, describe, "#{search_title} — which episode?", ctx_of, rt_of) ||
            back()

        n = episode.number
        sources = anime_episode_sources(search_title, n, kitsu.anidb, kitsu.kitsu_id)
        q = Sources.anime_episode_query(search_title, n)

        with_library(q, sources)
        |> probe_and_pick([episode: n], anime_ctx(title, details, n, search_title))
    end
  end

  defp anime_ctx(title, details, episode, search_title) do
    build_ctx(title.type, title.id, title.title,
      episode: episode,
      poster_path: details["poster_path"],
      anime: true,
      search_title: search_title
    )
  end

  # Anime seasons live as separate Kitsu entries ("Attack on Titan",
  # "… Season 2", "… Final Season") — so the entry picker IS the season
  # selector. Auto-picks when there's only one match.
  defp kitsu_pick(name) do
    case Kitsu.search(name) do
      {:ok, []} ->
        %{anime: nil, episodes: [], anidb: nil, kitsu_id: nil}

      {:ok, [only]} ->
        kitsu_selected(only)

      {:ok, results} ->
        # Chronological, not by title — "Part 2"/"Final Season" naming makes
        # alphabetical order useless; year is the real season order. Stable
        # sort keeps same-year entries (S1 + its Part 2) in sane order.
        # Year ascending, but within a year the main TV season comes before
        # its ONA/OVA/special/movie spin-offs (watch order, not clutter first).
        results = Enum.sort_by(results, &{&1.year || "9999", subtype_rank(&1.subtype), &1.title})

        case pick(results, &describe_kitsu/1, "#{name} — which season/entry?", & &1.poster) do
          nil -> back()
          anime -> kitsu_selected(anime)
        end

      _ ->
        %{anime: nil, episodes: [], anidb: nil, kitsu_id: nil}
    end
  end

  # Non-interactive variant for resume/next-episode flows: the stored
  # search_title re-matches its own entry first, so no picker needed.
  defp kitsu_lookup(name) do
    case Kitsu.search(name) do
      {:ok, [anime | _]} -> kitsu_selected(anime)
      _ -> %{anime: nil, episodes: [], anidb: nil, kitsu_id: nil}
    end
  end

  defp kitsu_selected(anime) do
    # AniList-sourced entries (Kitsu down/slow) have no Kitsu id. Recover one
    # from the MAL id when possible — Torrentio's anime path is keyed by
    # Kitsu id, so this is what lets Russian/public trackers reach anime.
    kitsu_id =
      anime.id ||
        case anime[:mal_id] && Kitsu.kitsu_id_from_mal(anime.mal_id) do
          {:ok, id} -> id
          _ -> nil
        end

    anidb =
      with id when not is_nil(id) <- kitsu_id,
           {:ok, mapped} <- Kitsu.anidb_id(id) do
        mapped
      else
        _ -> nil
      end

    %{anime: anime, episodes: kitsu_episode_list(anime), anidb: anidb, kitsu_id: kitsu_id}
  end

  # TV seasons sort ahead of everything else within a year; movies next,
  # then the OVA/ONA/special extras. Handles AniList (TV/TV_SHORT/MOVIE/
  # SPECIAL/OVA/ONA) and Kitsu (TV/movie/special/…) casing.
  defp subtype_rank(subtype) do
    case subtype |> to_string() |> String.downcase() do
      t when t in ["tv", "tv_short"] -> 0
      "movie" -> 1
      _ -> 2
    end
  end

  defp describe_kitsu(a) do
    eps = if a.episode_count, do: " · #{a.episode_count} eps", else: ""
    "#{a.title} (#{a.year || "?"}) · #{a.subtype}#{eps}"
  end

  defp kitsu_episode_list(%{episode_count: count}) when is_integer(count) and count > 0,
    do: Enum.map(1..count, &%{number: &1, name: nil})

  # No count and no Kitsu id to fetch an episode list from (AniList entry).
  defp kitsu_episode_list(%{id: nil}), do: []

  defp kitsu_episode_list(anime) do
    {:ok, episodes} = Kitsu.episodes(anime.id)
    episodes
  end

  # Returns episode-specific releases first, then the show's batch packs
  # (either can contain the episode; RD's file picker extracts it).
  defp anime_episode_sources(search_title, episode, anidb, kitsu_id) do
    {:ok, sources, _scope} =
      Sources.anime_episode_search(search_title, episode,
        anidb_id: anidb,
        kitsu_id: kitsu_id,
        search_title: search_title
      )

    sources
  end

  # Fold per-episode titles/air dates into the bare numbered list, and
  # append upcoming episodes the count doesn't include yet (with air dates,
  # so "when's the next one?" is answered right in the picker).
  defp enrich_episodes(episodes, details) when map_size(details) > 0 do
    known = MapSet.new(episodes, & &1.number)

    enriched =
      Enum.map(episodes, fn ep -> Map.merge(ep, Map.get(details, ep.number) || %{}) end)

    upcoming =
      details
      |> Enum.reject(fn {n, _} -> MapSet.member?(known, n) end)
      |> Enum.map(fn {n, d} -> Map.put(d, :number, n) end)

    Enum.sort_by(enriched ++ upcoming, & &1.number)
  end

  defp enrich_episodes(episodes, _details), do: episodes

  defp describe_anime_episode(ep) do
    name = Map.get(ep, :name)

    date =
      case Map.get(ep, :airdate) do
        nil ->
          ""

        d ->
          case {Map.get(ep, :future), days_until(d)} do
            {true, ""} -> " · airs #{d}"
            {true, countdown} -> " · #{d}#{countdown}"
            {_, _} -> " · #{d}"
          end
      end

    "E#{pad2(ep.number)}#{if name in [nil, ""], do: "", else: " #{name}"}#{date}"
  end

  defp title_sources("movie", name, year, imdb, _season, _episode) do
    q = Enum.join(Enum.reject([name, year], &is_nil/1), " ")
    with_library(q, find_sources(q, imdb && {:movie, imdb}))
  end

  defp title_sources("tv", name, _year, imdb, season, episode) do
    q = Sources.episode_query(name, season, episode)
    with_library(q, find_sources(q, imdb && {:series, imdb, season, episode}))
  end

  # Torrents already in the user's debrid account come first — instant and
  # guaranteed to play. Dedup by hash, keeping the library entry.
  defp with_library(query, found) do
    library = query |> RD.library() |> Enum.map(&Sources.account_source/1)

    # Rank the merged list: library entries arrive in RD-account order (most
    # recently added first), which looks like random tier/size jumble in the
    # picker — the score puts them 4K-first, bigger-first like everything.
    (library ++ found)
    |> Enum.uniq_by(& &1.hash)
    |> Sources.rank()
  end

  defp rd_opts(season, episode) do
    Enum.reject([season: season, episode: episode], fn {_k, v} -> is_nil(v) end)
  end

  # ── featured (trending on TMDB) ───────────────────────────────────

  defp featured do
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: laev setup")
    end

    unless Tmdb.configured?() do
      die("featured needs TMDB_API_KEY — add it to #{Config.path()} or the environment")
    end

    type =
      case pick(["movies", "shows", "anime"], &String.capitalize/1, "what are you in the mood for?") do
        "movies" -> "movie"
        "shows" -> "tv"
        "anime" -> :anime
        nil -> back()
      end

    title = pick_featured(type, 1, []) || back()
    play_title(title)
  end

  defp pick_featured(type, page, acc) do
    {results, more?} =
      case featured_page(type, page) do
        {:ok, results, more?} -> {results, more?}
        {:error, reason} -> die(tmdb_error(reason, "trending lookup"))
      end

    titles = Enum.uniq_by(acc ++ results, &{&1.type, &1.id})
    items = if more?, do: titles ++ [:more], else: titles

    case pick_with_save(items, featured_header(type)) do
      :more -> pick_featured(type, page + 1, titles)
      other -> other
    end
  end

  defp featured_page(:anime, page), do: Tmdb.discover_anime(page)
  defp featured_page(type, page), do: Tmdb.trending(type, page)

  defp featured_header(:anime), do: "popular anime"
  defp featured_header("movie"), do: "trending movies this week"
  defp featured_header("tv"), do: "trending shows this week"

  defp split_year(query) do
    case Regex.run(~r/^(.*?)\s+((?:19|20)\d{2})\s*$/, String.trim(query)) do
      [_, rest, year] when rest != "" -> {rest, String.to_integer(year)}
      _ -> {query, nil}
    end
  end

  # Show a page of TMDB titles (year-matches first when a year was given),
  # with a "more results" entry while further pages exist.
  # TMDB does not cross-match British/American spellings ("In the Grey" is
  # invisible to a "gray" query), so search every spelling variant and merge.
  @spelling_pairs [
    {"gray", "grey"},
    {"color", "colour"},
    {"theater", "theatre"},
    {"harbor", "harbour"},
    {"armor", "armour"},
    {"honor", "honour"}
  ]

  defp spelling_variants(q) do
    d = String.downcase(q)

    extra =
      Enum.flat_map(@spelling_pairs, fn {a, b} ->
        cond do
          String.contains?(d, a) -> [String.replace(d, a, b)]
          String.contains?(d, b) -> [String.replace(d, b, a)]
          true -> []
        end
      end)

    Enum.uniq([q | extra])
  end

  defp canonical(s) do
    d = s |> String.trim() |> String.downcase()
    Enum.reduce(@spelling_pairs, d, fn {a, b}, acc -> String.replace(acc, b, a) end)
  end

  defp pick_title(q, year, page, acc) do
    {results, more?} =
      q
      |> spelling_variants()
      |> Enum.map(fn variant ->
        case Tmdb.search(variant, page) do
          {:ok, results, more?} -> {results, more?}
          {:error, reason} -> die(tmdb_error(reason, "search"))
        end
      end)
      |> then(fn pages ->
        {Enum.flat_map(pages, &elem(&1, 0)), Enum.any?(pages, &elem(&1, 1))}
      end)

    titles = Enum.uniq_by(acc ++ results, &{&1.type, &1.id})

    cond do
      titles == [] and not more? ->
        die("no movies or shows on TMDB match \"#{q}\"")

      titles == [] ->
        pick_title(q, year, page + 1, acc)

      true ->
        titles = rank_titles(titles, q, year)
        items = if more?, do: titles ++ [:more], else: titles

        # Any result being part of a curated franchise puts the whole franchise
        # at the top, above the ordinary results. Matching is by TMDB id rather
        # than by what was typed, so searching one film offers its franchise:
        # "order of the phoenix" surfaces Harry Potter just as "harry potter"
        # does, with the film itself still the first ordinary result.
        # A title is often in more than one list — Spider-Man is its own
        # franchise and part of Marvel — so offer each, narrowest first. With
        # nothing curated, TMDB's own collection stands in, which covers the
        # series it groups correctly without anyone having to list them.
        franchises =
          case Laev.Franchises.detect(titles) do
            [] -> List.wrap(tmdb_collection_franchise(titles))
            curated -> curated
          end

        items = Enum.map(franchises, &{:franchise, &1}) ++ items

        header =
          "what to watch? (#{length(titles)} results" <>
            if(more?, do: ", more available)", else: ", all shown)")

        case pick_with_save(items, header) do
          :more -> pick_title(q, year, page + 1, titles)
          {:franchise, franchise} -> franchise_screen(franchise, q, year, page, titles)
          other -> other
        end
    end
  end

  # Which series the results are really about. Reading only the top hit was
  # wrong twice over: "pirate" led with Space Pirate Captain Harlock and
  # offered that, while "pirates" led with a film in no collection at all and
  # so offered nothing, even with five Pirates of the Caribbean films sitting
  # in the results. Weighing the whole page settles it — the series most of
  # the matches belong to wins, and the best-ranked one breaks a tie.
  defp likeliest_collection(titles) do
    titles
    |> Enum.filter(&(&1.type == "movie"))
    |> Enum.take(8)
    |> Task.async_stream(&collection_id_of/1, max_concurrency: 8, timeout: 15_000, on_timeout: :kill_task)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:ok, {id, votes}}, rank} when is_integer(id) -> [{id, {rank, votes}}]
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.max_by(fn {_id, hits} -> {length(hits), -best_rank(hits)} end, fn -> nil end)
    |> case do
      {id, hits} -> if convincing?(hits), do: id
      nil -> nil
    end
  end

  defp best_rank(hits), do: hits |> Enum.map(&elem(&1, 0)) |> Enum.min()

  # Two films of one series among the results is evidence by itself. A single
  # film is only evidence when it is the best result *and* a widely-seen one:
  # searching "dead man's chest" should offer Pirates of the Caribbean, while
  # "pirate" — which returns no Pirates films at all, just obscure films of
  # that name — shouldn't have the one series among them dressed up as the
  # answer. Vote count is the steadier measure of that; popularity moves daily.
  @franchise_hint_votes 2_000

  defp convincing?(hits) do
    length(hits) > 1 or
      Enum.any?(hits, fn {rank, votes} -> rank == 0 and votes >= @franchise_hint_votes end)
  end

  defp collection_id_of(%{id: id}) do
    case fetch_details(%{type: "movie", id: id}) do
      {:ok, %{"belongs_to_collection" => %{"id" => collection_id}} = details} ->
        {collection_id, details["vote_count"] || 0}

      _ ->
        nil
    end
  end

  # TMDB files most series in a "collection" of its own, and for the ones it
  # gets right that is as good as a curated list — so the collection becomes a
  # franchise with the same shape, and the rest of the flow can't tell the
  # difference. It keys off the films rather than the query, which is what
  # makes searching "dead man's chest" offer Pirates of the Caribbean.
  defp tmdb_collection_franchise(titles) do
    with collection_id when is_integer(collection_id) <- likeliest_collection(titles),
         {:ok, %{"parts" => parts, "name" => name}} when length(parts) > 1 <- Tmdb.collection(collection_id) do
      %{
        name: String.replace(name, ~r/ Collection$/, ""),
        source: :tmdb,
        tiers: [],
        entries:
          parts
          |> Enum.map(
            &%{
              type: "movie",
              tmdb_id: &1["id"],
              season: nil,
              title: &1["title"],
              date: &1["release_date"] || "",
              tiers: []
            }
          )
          |> Enum.sort_by(&if(&1.date in [nil, ""], do: "9999", else: &1.date))
      }
    else
      _ -> nil
    end
  end

  # The curated franchise behind a search result. A franchise big enough to have
  # tiers asks which list first — sixty-odd Marvel titles is not something to
  # open flat on someone — and everything else goes straight to the list.
  defp franchise_screen(franchise, q, year, page, acc) do
    if Laev.Franchises.tiered?(franchise) do
      options =
        Enum.map(franchise.tiers, fn tier ->
          count = length(Laev.Franchises.entries(franchise, tier.key))
          {tier.key, "#{tier.label} — #{count} titles" <> if(tier.blurb, do: " · #{tier.blurb}", else: "")}
        end)

      case pick(options, &elem(&1, 1), "#{franchise.name} — which list?") do
        nil -> pick_title(q, year, page, acc)
        {tier, _} -> franchise_list(franchise, tier, q, year, page, acc)
      end
    else
      franchise_list(franchise, "all", q, year, page, acc)
    end
  end

  # Titles are taken from TMDB so the list looks like every other picker — same
  # posters, same years — while the curated file decides only membership, order
  # and which tier a title belongs to.
  defp franchise_list(franchise, tier, q, year, page, acc) do
    titles =
      franchise
      |> Laev.Franchises.entries(tier)
      |> Task.async_stream(&franchise_title/1, max_concurrency: 8, timeout: 20_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, title} when is_map(title) -> [title]
        _ -> []
      end)

    label =
      case Laev.Franchises.tier_label(franchise, tier) do
        nil -> franchise.name
        name -> "#{franchise.name} · #{name}"
      end

    case pick_with_save(titles, "#{label} — #{length(titles)} titles, in release order") do
      # Esc goes back a level: to the tier chooser where there is one, and to
      # the search results where there isn't.
      nil ->
        if Laev.Franchises.tiered?(franchise),
          do: franchise_screen(franchise, q, year, page, acc),
          else: pick_title(q, year, page, acc)

      {:franchise, _} ->
        franchise_list(franchise, tier, q, year, page, acc)

      chosen ->
        chosen
    end
  end

  defp season_title(name, nil), do: name
  defp season_title(name, season), do: "#{name} · Season #{season}"

  defp franchise_title(entry) do
    case fetch_details(%{type: entry.type, id: entry.tmdb_id}) do
      {:ok, details} ->
        %{
          id: entry.tmdb_id,
          type: entry.type,
          season: entry.season,
          title: season_title(details["title"] || details["name"] || entry.title, entry.season),
          year: Tmdb.year(details["release_date"] || details["first_air_date"]),
          poster: Tmdb.poster_url(details["poster_path"], "w342"),
          overview: details["overview"],
          vote: details["vote_average"],
          popularity: details["popularity"]
        }

      _ ->
        # TMDB unreachable for this one — the curated file still knows what it is.
        %{
          id: entry.tmdb_id,
          type: entry.type,
          season: entry.season,
          title: season_title(entry.title, entry.season),
          year: Tmdb.year(entry.date),
          poster: nil,
          overview: nil,
          vote: nil,
          popularity: nil
        }
    end
  end

  defp title_poster(:more), do: nil
  defp title_poster({:franchise, _}), do: nil
  defp title_poster(title), do: title.poster

  # Exact-title matches first (newest first — a remake outranks the original),
  # then the rest by TMDB popularity. A requested year trumps both, softly
  # (±1: release dates shift between regions and announcements).
  defp rank_titles(titles, query, year) do
    q = canonical(query)

    Enum.sort_by(titles, fn t ->
      yr = t.year && String.to_integer(t.year)

      year_rank =
        cond do
          year == nil -> 0
          yr == year -> 0
          is_integer(yr) and abs(yr - year) <= 1 -> 1
          true -> 2
        end

      if canonical(t.title || "") == q do
        {year_rank, 0, -(yr || 0)}
      else
        {year_rank, 1, -(t.popularity || 0)}
      end
    end)
  end

  # Title picker with watchlist pinning: ctrl-s toggles the hovered title
  # (📌 appears immediately), cursor stays put; enter selects as usual.
  defp pick_with_save(items, header, initial \\ 0) do
    describe = fn
      :more -> describe_title_item(:more)
      t -> pin_mark(t) <> describe_title_item(t)
    end

    result =
      pick(
        items,
        describe,
        header <> " · ctrl-s pins · ctrl-o info",
        &title_poster/1,
        initial,
        ["ctrl-s", "ctrl-o"]
      )

    case result do
      nil ->
        nil

      {"ctrl-s", :more} ->
        pick_with_save(items, header, Enum.find_index(items, &(&1 == :more)) || 0)

      {"ctrl-o", :more} ->
        pick_with_save(items, header, Enum.find_index(items, &(&1 == :more)) || 0)

      {key, {:franchise, _} = row} when key in ["ctrl-s", "ctrl-o"] ->
        # Pinning or opening a page only means something for a title.
        pick_with_save(items, header, Enum.find_index(items, &(&1 == row)) || 0)

      {"ctrl-o", title} ->
        open_media_page(title.type, title.id, title.title)
        pick_with_save(items, header, Enum.find_index(items, &(&1 == title)) || 0)

      {"ctrl-s", title} ->
        # Pinning pre-warms the calendar cache in the background, so the
        # calendar opens instantly instead of fetching per-title on entry.
        if Laev.Watchlist.toggle(title) == :added do
          Laev.Calendar.warm(%{
            "type" => title.type,
            "tmdb_id" => title.id,
            "title" => title.title
          })
        end

        Laev.Sync.live_push()
        pick_with_save(items, header, Enum.find_index(items, &(&1 == title)) || 0)

      {nil, item} ->
        item
    end
  end

  defp pin_mark({:franchise, _}), do: ""

  defp pin_mark(t),
    do: if(Laev.Watchlist.has?(t.type, t.id), do: "≡ ", else: "")

  defp describe_title_item(:more), do: "⋯ more results"

  defp describe_title_item({:franchise, f}) do
    films = Enum.count(f.entries, &(&1.type == "movie"))
    shows = length(f.entries) - films
    kind = if Map.get(f, :source) == :tmdb, do: "the series", else: "curated list"

    IO.ANSI.format([
      :bright,
      "🎬 #{f.name} — #{kind}",
      :reset,
      :faint,
      "  #{films} films#{if shows > 0, do: " · #{shows} TV", else: ""} · in release order",
      :reset
    ])
    |> IO.iodata_to_binary()
  end

  defp describe_title_item(title), do: describe_title(title)

  defp fetch_details(%{type: "movie", id: id}), do: Tmdb.movie(id)
  defp fetch_details(%{type: "tv", id: id}), do: Tmdb.tv(id)

  defp pick_episode(details, preselect \\ nil) do
    seasons = Enum.filter(details["seasons"] || [], &(&1["season_number"] > 0))
    if seasons == [], do: die("TMDB lists no seasons for this show")

    show = details["name"] || details["title"] || ""

    # A franchise list names the season it means, so don't ask again.
    season =
      case preselect && Enum.find(seasons, &(&1["season_number"] == preselect)) do
        nil -> pick(seasons, &describe_season/1, "#{show} — which season?") || back()
        chosen -> chosen
      end
    season_number = season["season_number"]

    episodes =
      case Tmdb.season(details["id"], season_number) do
        {:ok, %{"episodes" => episodes}} when episodes != [] -> episodes
        {:ok, _} -> die("TMDB lists no episodes for season #{season_number}")
        {:error, reason} -> die(tmdb_error(reason, "season lookup"))
      end

    ctx_of = fn e ->
      %{type: "tv", tmdb_id: details["id"], season: season_number, episode: e["episode_number"]}
    end

    rt_of = fn e -> runtime_seconds(e["runtime"]) end
    describe = fn e -> watched_label(ctx_of.(e), describe_episode(e), rt_of.(e)) end

    episode =
      pick_episodes(episodes, describe, "#{show} S#{pad2(season_number)} — which episode?", ctx_of, rt_of) ||
        back()

    {season_number, episode["episode_number"]}
  end

  # TMDB/AniList give episode runtime in minutes; nil when unknown (then
  # only a "done" marker counts as watched).
  defp runtime_seconds(min) when is_integer(min) and min > 0, do: min * 60
  defp runtime_seconds(_), do: nil

  # Episode picker with two watched-state shortcuts (for fixing marks and
  # bulk catch-up):
  #   ctrl-w  toggle the highlighted episode watched/unwatched
  #   alt-w   mark the highlighted episode AND every earlier one watched —
  #           "I've seen everything up to here" in one press
  # `ctx_of` maps an episode to its position ctx, `rt_of` to runtime seconds.
  # Reopens at the same row after a change. (ctrl-shift-w is indistinguishable
  # from ctrl-w in a terminal, so alt-w carries the bulk action.)
  defp pick_episodes(items, describe, header, ctx_of, rt_of, initial \\ 0) do
    hint = header <> " · ctrl-w toggles · alt-w marks through here"

    case pick(items, describe, hint, nil, initial, ["ctrl-w", "alt-w"]) do
      nil ->
        nil

      {"ctrl-w", ep} ->
        ctx = ctx_of.(ep)
        Laev.Position.set_watched(ctx, not Laev.Position.watched?(ctx, rt_of.(ep)))
        Laev.Sync.live_push()
        reopen_episodes(items, describe, header, ctx_of, rt_of, ep)

      {"alt-w", ep} ->
        index = Enum.find_index(items, &(&1 == ep)) || 0

        for e <- Enum.take(items, index + 1),
            do: Laev.Position.set_watched(ctx_of.(e), true)

        Laev.Sync.live_push()
        reopen_episodes(items, describe, header, ctx_of, rt_of, ep)

      {nil, ep} ->
        ep
    end
  end

  defp reopen_episodes(items, describe, header, ctx_of, rt_of, ep) do
    pick_episodes(items, describe, header, ctx_of, rt_of, Enum.find_index(items, &(&1 == ep)) || 0)
  end

  # A watched episode reads as a grayed-out "✓ …" line so finished vs. unseen
  # is obvious at a glance (fzf renders the ANSI because pickers pass --ansi);
  # unwatched keeps a 2-space indent so the ✓ column stays aligned.
  defp watched_label(ctx, text, runtime_s \\ nil) do
    if Laev.Position.watched?(ctx, runtime_s) do
      IO.iodata_to_binary(IO.ANSI.format_fragment([:faint, "✓ ", text, :reset]))
    else
      "  " <> text
    end
  end

  defp find_sources(query, torrentio) do
    IO.puts(:stderr, "searching sources: #{query}")
    opts = if torrentio, do: [backend: :apibay, torrentio: torrentio], else: [backend: :apibay]

    case Sources.search(query, opts) do
      {:ok, []} -> die("no sources found for \"#{query}\"")
      {:ok, sources} -> sources
      {:error, reason} -> die("source search failed: #{inspect(reason)}")
    end
  end

  defp describe_title(t) do
    kind = if t.type == "tv", do: "series", else: "movie"
    rating = if t.vote && t.vote > 0, do: " · ★ #{Float.round(t.vote * 1.0, 1)}"
    "#{t.title} (#{t.year || "?"}) · #{kind}#{rating}"
  end

  defp describe_season(s) do
    count = if s["episode_count"], do: " · #{s["episode_count"]} episodes"
    "S#{pad2(s["season_number"])} #{s["name"]}#{count}"
  end

  defp describe_episode(e) do
    # days_until is empty for past dates, so aired episodes show just the
    # date and unaired ones get the countdown — same as the anime picker.
    date = if e["air_date"] not in [nil, ""], do: " · #{e["air_date"]}#{days_until(e["air_date"])}"
    "E#{pad2(e["episode_number"])} #{e["name"]}#{date}"
  end

  defp days_until(iso_date) do
    case Date.from_iso8601(iso_date) do
      {:ok, date} ->
        case Date.diff(date, Date.utc_today()) do
          0 -> " · today!"
          1 -> " · tomorrow"
          n when n > 1 -> " · in #{n}d"
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp pad2(n), do: String.pad_leading("#{n}", 2, "0")

  # Probe sources on RD one page at a time and only offer the ones that
  # actually play. A playable entry carries its resolved stream, so Enter
  # plays instantly. Playable finds carry over between pages; probing more
  # is an explicit picker choice, not an endless background churn.
  @probe_page 8

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far \\ [], sub_task \\ nil)

  defp probe_and_pick([], _rd_opts, _ctx, [], _sub_task) do
    die("no playable sources — try another title or release")
  end

  defp probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task) do
    if Process.get(:laev_auto) do
      auto_play(sources, rd_opts, ctx)
    else
      do_probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task)
    end
  end

  # --auto: no source picker — walk the ranked list and play the first
  # source that actually resolves (RD.resolve_best stops at the first hit,
  # so nothing beyond it is probed).
  defp auto_play(sources, rd_opts, ctx) do
    sub_task = if Process.get(:laev_mode, :play) == :play, do: start_subtitle_task(ctx)
    IO.puts(:stderr, "auto — trying sources best-first…")

    notify = fn
      {:trying, name} ->
        IO.puts(:stderr, "  → #{String.slice(name, 0, 70)}")

      {:skipped, name, reason} ->
        IO.puts(:stderr, "  ✗ #{String.slice(name, 0, 55)} — #{unplayable_reason(reason)}")
    end

    case Providers.resolve_best(sources, Keyword.put(rd_opts, :notify, notify)) do
      {:ok, stream, source, _skipped} ->
        finish_play(ctx, source, stream, sub_task)

      {:error, {:all_failed, _skipped}} ->
        if sub_task, do: Task.shutdown(sub_task, :brutal_kill)
        die("no playable sources — try again without --auto to see the full list")
    end
  end

  defp do_probe_and_pick(sources, rd_opts, ctx, playable_so_far, sub_task) do
    # Fetch subtitles in the background while sources are being probed, so
    # the network round-trips overlap instead of delaying the mpv launch.
    sub_task = sub_task || start_subtitle_task(ctx)
    # Quality-diverse page: some of every resolution tier gets probed up
    # front, so picking 1080p never requires wading through all the 4Ks.
    {page, rest} = Sources.probe_page(sources, @probe_page)

    IO.puts(
      :stderr,
      "checking #{length(page)} sources (#{length(rest)} more unchecked)…"
    )

    parent = self()

    notify = fn {:result, index, source, result} ->
      case result do
        {:ok, stream} ->
          IO.puts(:stderr, "  ✓ #{source.name}#{provider_tag(stream)}")
          send(parent, {:playable, index, source, stream})

        {:error, reason} ->
          IO.puts(:stderr, "  ✗ #{source.name} — #{unplayable_reason(reason)}")
      end
    end

    Providers.probe_sources(Enum.with_index(page), Keyword.put(rd_opts, :notify, notify))
    # Global re-rank on every page: appended pages would otherwise stack
    # below earlier finds (a page-2 4K under a page-1 720p).
    playable = Sources.rank_playable(playable_so_far ++ collect_playable())

    case {playable, rest} do
      {[], []} ->
        die("no playable sources — try another title or release")

      {[], rest} ->
        IO.puts(:stderr, "none playable yet — checking the next page…")
        probe_and_pick(rest, rd_opts, ctx, [], sub_task)

      {playable, rest} ->
        offer_playable(playable, rest, rd_opts, ctx, sub_task)
    end
  end

  # The source picker over already-probed results. The probe session is
  # remembered per title (process-local), so "try another source" from the
  # post-play menu comes straight back here — every checked source still
  # listed, "check more" continuing from the unprobed remainder — instead
  # of re-searching and re-probing the same pages.
  defp offer_playable(playable, rest, rd_opts, ctx, sub_task) do
    save_probe_state(ctx, playable, rest, rd_opts)
    items = if rest == [], do: playable, else: playable ++ [:more]

    case pick(items, &describe_playable/1, "which source? (all checked + playable)") do
      nil ->
        if sub_task, do: Task.shutdown(sub_task, :brutal_kill)
        back()

      :more ->
        probe_and_pick(rest, rd_opts, ctx, playable, sub_task)

      {source, stream} ->
        finish_play(ctx, source, stream, sub_task)
    end
  end

  defp save_probe_state(nil, _playable, _rest, _rd_opts), do: :ok

  defp save_probe_state(ctx, playable, rest, rd_opts),
    do: Process.put({:laev_sources, sources_key(ctx)}, {playable, rest, rd_opts})

  defp sources_key(ctx), do: {ctx.type, ctx.tmdb_id, ctx[:season], ctx[:episode]}

  defp finish_play(ctx, source, stream, sub_task) do
    case Process.get(:laev_mode, :play) do
      :download ->
        if sub_task, do: Task.shutdown(sub_task, :brutal_kill)
        download_stream(stream)

      :play ->
        Player.open(
          :mpv,
          stream.url,
          await_subtitles(sub_task) ++ position_args(ctx, stream.filename) ++ Laev.Skip.script_args()
        )

        save_resume(ctx, source)
        start_mal_scrobbler(ctx)

        # Push the fresh resume entry (title + torrent source) right away, so
        # another device can already continue this title mid-playback…
        cond do
          Laev.Sync.auto?() -> Laev.Sync.sync_quiet("saved")
          Laev.Sync.live?() -> Laev.Sync.live_push()
          true -> :ok
        end

        # …and push again when playback actually ends: mpv runs detached, so
        # the sync above happens at launch and never sees this session's
        # final position or watched flag.
        start_sync_watcher(ctx)

        IO.puts(:stderr, "playing in mpv: #{stream.filename}")

        binge? = Process.get(:laev_binge) || Config.autoplay?()

        if binge? and ctx && is_integer(ctx.episode),
          do: binge_wait(ctx),
          else: post_play_menu(ctx, stream)
    end
  end

  # ── binge mode (auto-next on episode end) ─────────────────────────
  # laev stays alive watching the position file the Lua tracker writes:
  # "done" (mpv hit eof) → countdown → next episode, auto-picked. A stale
  # file (no save for 25s while the tracker saves every 5s) means the user
  # closed mpv mid-episode — binge ends quietly.

  defp binge_wait(ctx) do
    IO.puts(
      :stderr,
      IO.ANSI.format([
        :faint,
        "binge mode: next episode starts when this one ends (Ctrl-C quits laev, mpv keeps playing)",
        :reset
      ])
    )

    watch_for_eof(ctx, System.os_time(:second))
  end

  defp watch_for_eof(ctx, started_at) do
    Process.sleep(3_000)

    cond do
      Laev.Position.finished?(ctx) ->
        countdown_next(ctx)

      stale?(ctx, started_at) ->
        IO.puts(:stderr, "mpv closed mid-episode — leaving binge mode")

      true ->
        watch_for_eof(ctx, started_at)
    end
  end

  # No position save for 25s (tracker writes every 5s) = mpv is gone. The
  # started_at grace period covers mpv's startup before the first save.
  defp stale?(ctx, started_at) do
    now = System.os_time(:second)

    case Laev.Position.last_saved_at(ctx) do
      nil -> now - started_at > 60
      mtime -> now - mtime > 25
    end
  end

  defp countdown_next(ctx) do
    case next_target(ctx) do
      nil ->
        IO.puts(:stderr, "\n  ✓ that was the last episode available — binge complete")

      next ->
        preview = %{ctx | season: next.season, episode: next.episode}
        IO.puts(:stderr, "")

        for n <- 10..1//-1 do
          IO.write(:stderr, "\r  ⚡ next: #{playing_desc(preview)} in #{n}s… (Ctrl-C stops) ")
          Process.sleep(1_000)
        end

        IO.puts(:stderr, "")
        Process.put(:laev_auto, true)
        play_to(ctx, next)
    end
  end

  # ── post-play controls (mov-cli style) ────────────────────────────
  # mpv runs detached, so instead of exiting we stay on a control screen
  # while the video plays: chain into the next episode, replay, go back to
  # picking, or quit. Esc/quit leaves mpv running.

  defp post_play_menu(nil, _stream), do: :ok

  defp post_play_menu(ctx, stream) do
    if tty?() do
      clear_screen()

      IO.puts(
        :stderr,
        IO.ANSI.format([
          "\n  ▶ ",
          :bright,
          "Now Playing",
          :reset,
          ": ",
          :cyan,
          playing_desc(ctx),
          :reset,
          "\n"
        ])
      )

      # The launch-time stinger alert gets wiped by this screen — repeat it
      # here, where it stays visible for the whole watch. Cache-warm by the
      # pre-launch task, so this never waits on TMDB.
      case Laev.Skip.stinger_parts(ctx) do
        [] ->
          :ok

        parts ->
          IO.puts(
            :stderr,
            IO.ANSI.format([
              :yellow,
              "  🎬 #{Laev.Skip.stinger_label(parts)}",
              :reset,
              :faint,
              " — worth staying through the credits\n",
              :reset
            ])
          )
      end

      episodic? = is_integer(ctx.episode)
      next = if episodic?, do: next_target(ctx)

      items =
        List.flatten([
          if(next, do: [{:next, "⏭  #{next.label}"}], else: []),
          if(next, do: [{:binge, "⚡  autoplay — chain next episodes"}], else: []),
          {:replay, "↻  replay"},
          if(ctx[:anime],
            do: [{:mal_open, "★  open in MyAnimeList — in browser"}],
            else: [{:imdb, "★  rate on IMDb — open in browser"}]
          ),
          if(ctx[:anime] and Laev.MAL.authenticated?(), do: [{:mal_rate, "☆  rate on MyAnimeList"}], else: []),
          {:switch, "⇄  try another source"},
          if(episodic? and ctx.episode > 1, do: [{:previous, "⏮  previous episode"}], else: []),
          if(episodic?,
            do: [{:select, "☰  episodes — choose another"}, {:search, "⌕  search — find something else"}],
            else: [{:select, "⌕  search — find something else"}]
          ),
          {:home, "⌂  home — back to the menu (keeps playing)"},
          {:quit, "✕  quit"}
        ])

      case pick(items, &elem(&1, 1), "what next? · esc goes back to the menu") do
        {:next, _} -> play_to(ctx, next)
        {:binge, _} ->
          Process.put(:laev_binge, true)
          binge_wait(ctx)
        {:replay, _} -> replay(ctx, stream)
        {:switch, _} -> switch_source(ctx)
        {:previous, _} -> play_adjacent(ctx, -1)
        {:select, _} -> reselect(ctx)
        {:imdb, _} ->
          open_imdb(ctx)
          post_play_menu(ctx, stream)
        {:mal_open, _} ->
          open_mal(ctx)
          post_play_menu(ctx, stream)
        {:mal_rate, _} ->
          rate_on_mal(ctx)
          post_play_menu(ctx, stream)
        {:search, _} -> menu_search()
        {:home, _} -> back()
        {:quit, _} -> quit_laev()
        # Esc backs out a level here like it does everywhere else, rather than
        # ending the session — mpv is detached, so the main menu is usable
        # (search something, queue what's next) while the current thing plays.
        _ -> back()
      end
    end
  end

  # Same URL again; position args resume from wherever the tracker last
  # saved, so "replay" doubles as "reopen where I was" after closing mpv.
  defp replay(ctx, stream) do
    args =
      subtitle_args(ctx) ++
        Laev.Skip.window_args(ctx) ++
        Laev.Skip.stinger_args(ctx) ++
        position_args(ctx, stream.filename) ++ Laev.Skip.script_args()

    Player.open(:mpv, stream.url, args)
    IO.puts(:stderr, "playing in mpv: #{stream.filename}")
    post_play_menu(ctx, stream)
  end

  # Next/previous episode: rebuild the play context with episode ± 1 and
  # rerun the full source flow (which respects --auto and re-enters this
  # menu after launch — that's the binge loop).
  # Play a specific season/episode target (from next_target). Rolls into the
  # next season when a season ended.
  defp play_to(ctx, %{season: s, episode: e}) do
    ctx = %{ctx | season: s, episode: e}
    clear_screen()
    IO.puts(:stderr, "#{playing_desc(ctx)} — finding sources…")
    play_entry(ctx_entry(ctx), rd_opts(ctx.season, ctx.episode))
  end

  defp play_adjacent(ctx, -1) do
    ctx = %{ctx | episode: ctx.episode - 1}
    clear_screen()
    IO.puts(:stderr, "#{playing_desc(ctx)} — finding sources…")
    play_entry(ctx_entry(ctx), rd_opts(ctx.season, ctx.episode))
  end

  # What "next" points at: the next episode in this season, the first episode
  # of the next season when this season is done, or nil when there's genuinely
  # nothing left (last aired episode / last season). Cached per title+ep so
  # re-showing the menu doesn't re-hit the network.
  defp next_target(%{episode: e} = ctx) when is_integer(e) do
    cache = {:next_target, ctx.tmdb_id, ctx.season, e, ctx[:anime]}

    case Process.get(cache, :miss) do
      :miss ->
        result = compute_next_target(ctx)
        Process.put(cache, result)
        result

      cached ->
        cached
    end
  end

  defp next_target(_ctx), do: nil

  defp compute_next_target(%{anime: true} = ctx) do
    # Anime uses absolute numbering within the picked entry; the next entry
    # (sequel season) is a separate manual pick, so we only roll within it.
    count = anime_episode_count(ctx[:search_title] || ctx.title)

    if is_integer(count) and ctx.episode >= count,
      do: nil,
      else: %{season: ctx.season, episode: ctx.episode + 1, label: "next episode"}
  end

  defp compute_next_target(%{season: s} = ctx) when is_integer(s) do
    cur = tv_season_episode_count(ctx.tmdb_id, s)

    cond do
      # More (aired) episodes left in this season.
      is_integer(cur) and ctx.episode < cur ->
        %{season: s, episode: ctx.episode + 1, label: "next episode"}

      # Season finished — roll into the next season if it has aired episodes.
      is_integer(cur) and tv_season_episode_count(ctx.tmdb_id, s + 1) not in [nil, 0] ->
        %{season: s + 1, episode: 1, label: "next season (S#{pad2(s + 1)})"}

      # Couldn't read counts — offer optimistically; a dead end is handled
      # gracefully at play time.
      is_nil(cur) ->
        %{season: s, episode: ctx.episode + 1, label: "next episode"}

      # This season is done and there's no next season: the end.
      true ->
        nil
    end
  end

  defp compute_next_target(ctx),
    do: %{season: ctx.season, episode: ctx.episode + 1, label: "next episode"}

  # Aired episodes in a TMDB season (air_date on or before today), or nil on
  # failure. Cached in-process.
  defp tv_season_episode_count(tmdb_id, season) do
    key = {:season_count, tmdb_id, season}

    case Process.get(key, :miss) do
      :miss ->
        count =
          case Tmdb.season(tmdb_id, season) do
            {:ok, %{"episodes" => eps}} when is_list(eps) ->
              today = Date.to_iso8601(Date.utc_today())
              Enum.count(eps, &(&1["air_date"] not in [nil, ""] and &1["air_date"] <= today))

            _ ->
              nil
          end

        Process.put(key, count)
        count

      cached ->
        cached
    end
  end

  defp anime_episode_count(title) do
    key = {:anime_count, title}

    case Process.get(key, :miss) do
      :miss ->
        count =
          case Kitsu.search(title) do
            {:ok, [%{episode_count: c} | _]} when is_integer(c) and c > 0 -> c
            _ -> nil
          end

        Process.put(key, count)
        count

      cached ->
        cached
    end
  end

  # Bad source (broken file, wrong audio, stutters): re-run the source flow
  # for the same title/episode and pick a different release. Position memory
  # is keyed by title, so the new source resumes at the same second — and
  # track memory correctly resets (ids don't carry across releases).
  defp switch_source(ctx) do
    clear_screen()

    case ctx && Process.get({:laev_sources, sources_key(ctx)}) do
      {playable, rest, rd_opts} ->
        IO.puts(
          :stderr,
          "#{playing_desc(ctx)} — every source you already checked (close the old mpv yourself)"
        )

        offer_playable(playable, rest, rd_opts, ctx, start_subtitle_task(ctx))

      _ ->
        IO.puts(:stderr, "#{playing_desc(ctx)} — finding sources (close the old mpv yourself)…")
        play_entry(ctx_entry(ctx), rd_opts(ctx.season, ctx.episode))
    end
  end

  defp reselect(ctx) do
    clear_screen()

    if is_integer(ctx.episode) do
      play_title(%{type: ctx.type, id: ctx.tmdb_id, title: ctx.title, year: nil})
    else
      menu_search()
    end
  end

  # Open the title's IMDb page in the browser (the user rates and logs
  # watched titles there). The IMDb id comes from TMDB's external ids; with
  # no match, fall back to an IMDb search for the title.
  defp open_imdb(ctx) do
    details = title_details(ctx.type, ctx.tmdb_id)
    browse(imdb_url(details, ctx.title))
  end

  # The reference page for a title on any of the list screens — search results,
  # featured, watchlist, calendar and history all carry a type, a TMDB id and a
  # title, just under different key shapes. Anime goes to MyAnimeList and
  # everything else to IMDb, the same split the post-play menu makes; which one
  # it is falls out of the TMDB details already fetched for the IMDb id, so the
  # branch costs no extra request.
  #
  # Neither page needs a MAL key. The anime id comes from AniList's public API
  # and the fallback is a plain MAL search url — MAL_CLIENT_ID is only ever for
  # scrobbling, so this works on an install that never logged in.
  defp open_media_page(type, tmdb_id, title) do
    details = title_details(type, tmdb_id)

    if anime?(details),
      do: browse(mal_url(title)),
      else: browse(imdb_url(details, title))
  end

  defp title_details(type, tmdb_id) do
    case fetch_details(%{type: type, id: tmdb_id}) do
      {:ok, details} -> details
      _ -> %{}
    end
  end

  defp imdb_url(details, title) do
    case Tmdb.imdb_id(details) do
      imdb when is_binary(imdb) -> "https://www.imdb.com/title/#{imdb}/"
      _ -> "https://www.imdb.com/find/?q=#{URI.encode_www_form(title || "")}"
    end
  end

  defp mal_url(title) do
    case mal_id_for(%{title: title}) do
      id when is_integer(id) -> "https://myanimelist.net/anime/#{id}"
      _ -> "https://myanimelist.net/anime.php?q=#{URI.encode_www_form(title || "")}"
    end
  end

  defp browse(url) do
    browser_open(url)
    IO.puts(:stderr, "opened in browser: #{url}")
  end

  # Anime → its MyAnimeList page (or a MAL search when the id is unknown),
  # the anime-native equivalent of the IMDb page for movies/shows.
  defp open_mal(ctx), do: browse(mal_url(ctx[:search_title] || ctx.title))

  # Detached, like the mpv launch — the browser must outlive laev.
  defp browser_open(url) do
    case System.find_executable("xdg-open") || System.find_executable("open") do
      nil -> IO.puts(:stderr, "no browser opener found — visit: #{url}")
      opener -> System.cmd("sh", ["-c", ~s("$@" >/dev/null 2>&1 &), "sh", opener, url])
    end
  end

  defp playing_desc(ctx) do
    cond do
      ctx.season && ctx.episode -> "#{ctx.title} S#{pad2(ctx.season)}E#{pad2(ctx.episode)}"
      ctx.episode -> "#{ctx.title} · Ep #{ctx.episode}"
      true -> ctx.title
    end
  end

  # RD hands us a plain HTTPS URL, so downloading is just curl with resume
  # support; its progress bar renders on stderr.
  defp download_stream(stream) do
    dir =
      Application.get_env(:laev_app, :download_dir) ||
        Path.join(System.user_home!(), "Videos")

    File.mkdir_p!(dir)
    dest = Path.join(dir, stream.filename)

    size =
      case stream.filesize do
        n when is_integer(n) and n > 0 -> " (#{Float.round(n / 1.0e9, 2)} GB)"
        _ -> ""
      end

    IO.puts(:stderr, "downloading #{stream.filename}#{size} → #{dest}")

    case System.cmd(
           "curl",
           ["-L", "--fail", "--retry", "3", "-C", "-", "--progress-bar", "-o", dest, stream.url]
         ) do
      {_, 0} ->
        IO.puts(:stderr, "✔ saved to #{dest}")
        IO.puts(Jason.encode!(%{downloaded: dest}))

      {_, code} ->
        die("download failed (curl exit #{code}) — partial file kept, rerun to resume")
    end
  end

  # Position tracking + exact resume: mpv gets a tiny Lua script that saves
  # the playback position every 5s (crash-safe), keyed by title+episode so
  # switching sources resumes from the same spot.
  defp position_args(ctx, filename \\ nil)
  defp position_args(nil, _filename), do: []

  defp position_args(ctx, filename) do
    case Laev.Position.mpv_args(ctx, filename) do
      {args, nil} ->
        args

      {args, resume_at} ->
        IO.puts(:stderr, "resuming from #{resume_at}")
        args
    end
  end

  # Subtitles and AniSkip windows both need network round-trips — fetch them
  # together in the background while sources are probed / RD resolves.
  defp start_subtitle_task(nil), do: nil

  defp start_subtitle_task(ctx),
    do:
      Task.async(fn ->
        subtitle_args(ctx) ++
          Laev.Skip.window_args(ctx) ++ Laev.Skip.stinger_args(ctx)
      end)

  defp await_subtitles(nil), do: []

  defp await_subtitles(task) do
    case Task.yield(task, 45_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, args} ->
        args

      _ ->
        IO.puts(:stderr, "subtitle fetch timed out — playing without")
        []
    end
  end

  # Fetch an external subtitle when a provider is configured (Jimaku for
  # anime, OpenSubtitles otherwise) and hand it to mpv. Silent when no
  # provider is set up — mpv still offers the stream's embedded tracks.
  defp subtitle_args(ctx) do
    case Config.subs_lang() do
      nil ->
        []

      lang ->
        case Laev.SubtitleFetch.fetch(ctx, lang) do
          {:ok, path, label} ->
            IO.puts(:stderr, "subtitles: #{label}")
            ["--sub-file=#{path}"]

          {:error, :no_provider} ->
            # No external subtitle provider configured — that's fine: mpv
            # auto-selects the embedded track in your language (--slang), so
            # this is the normal path, not an error. External subs
            # (OPENSUBTITLES_* / JIMAKU_API_KEY) are only a fallback for
            # releases that ship none. Stay quiet.
            []

          {:error, reason} ->
            IO.puts(:stderr, "no external subtitles (#{sub_reason(reason)}) — embedded tracks still available")
            []
        end
    end
  end

  defp tmdb_error({:tmdb, 401, _}, _op),
    do: "TMDB rejected the key (401) — check TMDB_API_KEY in #{Config.path()}"

  defp tmdb_error(reason, op), do: "TMDB #{op} failed: #{inspect(reason)}"

  defp sub_reason(:not_found), do: "none found for this title"
  defp sub_reason(:no_file), do: "no file for this episode/language"
  defp sub_reason(:opensubtitles_needs_login), do: "OpenSubtitles download needs username+password"
  defp sub_reason({:exception, message}), do: "subtitle fetch crashed: #{message}"
  defp sub_reason(reason), do: inspect(reason)

  # Remember what was played (episode + exact source) so `laev continue`
  # can jump straight back without re-hunting sources.
  defp save_resume(nil, _source), do: :ok

  defp save_resume(ctx, source) do
    entry =
      ctx_entry(ctx)
      |> Map.merge(%{
        "source" => %{"name" => source.name, "magnet" => source.magnet, "hash" => source.hash},
        "updated_at" => System.os_time(:second)
      })

    Laev.Resume.put(ctx.type, ctx.tmdb_id, entry)
  end

  # A ctx as a resume-style entry map — the inverse of entry_ctx/1, so the
  # post-play menu can feed play contexts back into the entry-based flow.
  defp ctx_entry(ctx) do
    %{
      "type" => ctx.type,
      "tmdb_id" => ctx.tmdb_id,
      "season" => ctx.season,
      "episode" => ctx.episode,
      "title" => ctx.title,
      "poster_path" => ctx[:poster_path],
      "anime" => ctx[:anime] || false,
      "search_title" => ctx[:search_title]
    }
  end

  defp describe_playable(:more), do: "⋯ check more sources"
  defp describe_playable({source, stream}), do: describe(source, stream)

  defp provider_tag(%{provider: :torbox}), do: "  ⚡TB"
  defp provider_tag(_stream), do: ""

  defp collect_playable(acc \\ []) do
    receive do
      {:playable, index, source, stream} -> collect_playable([{index, source, stream} | acc])
    after
      0 ->
        acc
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_index, source, stream} -> {source, stream} end)
    end
  end

  defp unplayable_reason({:not_cached, _status, _progress}), do: "not cached on Real-Debrid"
  defp unplayable_reason(:known_blocked), do: "blocked (known DMCA takedown)"
  defp unplayable_reason(:infringing), do: "infringing — taken down"
  defp unplayable_reason({:rd, 451, _}), do: "infringing — taken down"
  defp unplayable_reason(:no_video_files), do: "no video file in the torrent"
  defp unplayable_reason(:magnet_error), do: "bad magnet link"
  defp unplayable_reason(:no_seeders), do: "dead torrent — no seeders"

  defp unplayable_reason({:torrent_status, "error"}),
    do: "RD couldn't download it (usually no seeders)"

  defp unplayable_reason({:torrent_status, status}), do: "RD download failed (#{status})"
  defp unplayable_reason({:download_timeout, pct}), do: "RD download timed out at #{pct}%"
  defp unplayable_reason({:rd, 401, _}), do: rd_auth_error()
  defp unplayable_reason({:rd, 401}), do: rd_auth_error()
  defp unplayable_reason({:rd, status, _}), do: "Real-Debrid error #{status}"
  defp unplayable_reason({:rd, status}), do: "Real-Debrid error #{status}"
  defp unplayable_reason({:torbox, status, detail}), do: "TorBox: #{detail} (#{status})"
  defp unplayable_reason({:torbox, status}), do: "TorBox error #{status}"

  defp unplayable_reason(:no_provider_configured),
    do: "no debrid provider configured — run: laev setup"
  defp unplayable_reason(reason), do: inspect(reason)

  defp rd_auth_error,
    do: "Real-Debrid rejected the token (401) — check RD_TOKEN in #{Config.path()}"

  # ── continue watching ─────────────────────────────────────────────

  defp continue(initial \\ 0) do
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: laev setup")
    end

    case Laev.Resume.all() do
      [] ->
        nothing_here("Nothing in your history yet — watch something and it shows up here.")

      entries ->
        case pick(entries, &describe_resume/1, "continue watching · ctrl-o info", nil, initial, ["ctrl-o"]) do
          nil ->
            back()

          {"ctrl-o", entry} ->
            open_media_page(entry["type"], entry["tmdb_id"], entry["title"])
            continue(Enum.find_index(entries, &(&1 == entry)) || 0)

          {nil, entry} ->
            continue_entry(entry)
        end
    end
  end

  # An empty shelf is not a failure: in the menu say so and go back, rather
  # than halting the whole app the way a real error does. Piped and scripted
  # runs still get the JSON error and a non-zero exit, so a frontend driving
  # `laev continue` can still tell that there was nothing to play.
  defp nothing_here(message) do
    if tty?() do
      IO.puts(:stderr, IO.ANSI.format([:yellow, "\n  #{message}\n", :reset]))
      IO.gets("  press enter to go back… ")
      back()
    else
      die(message)
    end
  end

  # `laev resume`: straight back into the most recent thing — no picker.
  defp resume do
    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: laev setup")
    end

    case Laev.Resume.all() do
      [] ->
        nothing_here("Nothing in your history yet — watch something and it shows up here.")

      [entry | _] ->
        at =
          case Laev.Position.resume_at(entry_ctx(entry)) do
            nil -> ""
            time -> " · at #{time}"
          end

        IO.puts(:stderr, "resuming #{entry["title"]}#{entry_ep(entry)}#{at}")
        continue_entry(entry)
    end
  end

  defp continue_entry(entry) do
    rd_opts = rd_opts(entry["season"], entry["episode"])
    source = entry["source"]

    IO.puts(:stderr, "trying the source you last played: #{source["name"]}")

    # Subtitles fetch in the background while RD resolves.
    ctx = entry_ctx(entry)
    sub_task = start_subtitle_task(ctx)

    case Providers.resolve_magnet(source["magnet"], rd_opts) do
      {:ok, stream} ->
        Player.open(
          :mpv,
          stream.url,
          await_subtitles(sub_task) ++ position_args(ctx, stream.filename) ++ Laev.Skip.script_args()
        )
        Laev.Resume.put(
          entry["type"],
          entry["tmdb_id"],
          Map.put(entry, "updated_at", System.os_time(:second))
        )

        IO.puts(:stderr, "playing in mpv: #{stream.filename}")
        post_play_menu(ctx, stream)

      {:error, reason} ->
        Task.shutdown(sub_task, :brutal_kill)

        IO.puts(
          :stderr,
          "last source unavailable (#{unplayable_reason(reason)}) — searching fresh sources…"
        )

        play_entry(entry, rd_opts)
    end
  end

  # Run the full source flow for an entry map (a resume entry, or a ctx via
  # ctx_entry/1): fetch details, route anime vs standard, probe, pick, play.
  defp play_entry(entry, rd_opts) do
    type = entry["type"]

    unless Tmdb.configured?() do
      die("searching for sources needs TMDB_API_KEY — " <>
        "add it to #{Config.path()} or the environment")
    end

    details =
      case fetch_details(%{type: type, id: entry["tmdb_id"]}) do
        {:ok, details} -> details
        {:error, reason} -> die(tmdb_error(reason, "lookup"))
      end

    name = details["title"] || details["name"] || entry["title"]
    year = Tmdb.year(details["release_date"] || details["first_air_date"])
    ctx = entry_ctx(entry) |> Map.put(:title, name)

    cond do
      anime?(details) and type == "tv" and is_integer(entry["episode"]) ->
        # The stored search_title is the exact Kitsu entry (= season) the
        # user was watching — re-matching with it skips the season picker.
        kitsu = kitsu_lookup(entry["search_title"] || name)
        search_title = (kitsu.anime && kitsu.anime.title) || name
        n = entry["episode"]
        ctx = Map.merge(ctx, %{anime: true, search_title: search_title})

        Sources.anime_episode_query(search_title, n)
        |> with_library(anime_episode_sources(search_title, n, kitsu.anidb, kitsu.kitsu_id))
        |> probe_and_pick([episode: n], ctx)

      anime?(details) and type == "movie" ->
        kitsu = kitsu_lookup(entry["search_title"] || name)
        search_title = (kitsu.anime && kitsu.anime.title) || name
        ctx = Map.merge(ctx, %{anime: true, search_title: search_title})
        q = Sources.anime_movie_query(search_title)

        case Sources.search(q, backend: :anime) do
          {:ok, sources} -> with_library(q, sources) |> probe_and_pick([], ctx)
          {:error, reason} -> die("anime source search failed: #{inspect(reason)}")
        end

      true ->
        type
        |> title_sources(name, year, Tmdb.imdb_id(details), entry["season"], entry["episode"])
        |> probe_and_pick(rd_opts, ctx)
    end
  end

  defp describe_resume(entry) do
    ep =
      cond do
        entry["season"] && entry["episode"] ->
          " · S#{pad2(entry["season"])}E#{pad2(entry["episode"])}"

        entry["episode"] ->
          " · Ep #{entry["episode"]}"

        true ->
          ""
      end

    at =
      case Laev.Position.resume_at(entry_ctx(entry)) do
        nil -> ""
        time -> " · at #{time}"
      end

    "#{entry["title"]}#{ep}#{at} · last: #{String.slice(get_in(entry, ["source", "name"]) || "?", 0, 45)}"
  end

  # Let the user pick an item: fzf when available (arrows + fuzzy filter),
  # else a numbered prompt. Returns the chosen item, or nil on cancel.
  # `preview` maps an item to an image URL (or nil) — rendered next to the
  # list via chafa when both chafa and a URL are available.
  # `initial` restores the cursor to that item index — used by menus that
  # re-render after an action (settings), so the cursor doesn't jump home.
  # `expect`: extra keys (fzf --expect) that resolve the picker; with a
  # non-empty list the return shape becomes {key | nil, item} — nil key
  # means plain enter.
  # `resize`: what a live terminal resize does — :reflow (default) redraws
  # the fzf list at the new size; :abort exits the picker returning
  # :resized so the caller can rebuild static content (banner, calendar
  # grid) and reopen.
  defp pick(items, describe, header, preview \\ nil, initial \\ nil, expect \\ [], resize \\ :reflow) do
    if System.find_executable("fzf"),
      do: pick_fzf(items, describe, header, preview, initial, expect, resize),
      else: pick_number(items, describe, header, expect)
  end

  # Runs inside fzf's preview pane: {2} is the poster URL column. Downloads
  # once into a tmp cache, renders with chafa sized to the pane.
  #
  # Two portability guards, both learned from macOS: the cache name falls back
  # from md5sum (GNU) to md5 -q (BSD) to the bare URL, because an empty hash
  # made the "file" the cache directory itself and every preview came out
  # blank; and a failed render retries as block symbols, so a terminal-specific
  # format the local chafa doesn't have degrades to art instead of nothing.
  @poster_preview ~S"""
  url={2}; if [ "$url" = "-" ]; then echo; else d="${TMPDIR:-/tmp}/laev-posters"; mkdir -p "$d"; h=$(printf %s "$url" | md5sum 2>/dev/null | cut -c1-16); [ -n "$h" ] || h=$(printf %s "$url" | md5 -q 2>/dev/null | cut -c1-16); [ -n "$h" ] || h=$(printf %s "$url" | tr -dc 'A-Za-z0-9' | tail -c 24); f="$d/$h"; [ -s "$f" ] || curl -sL "$url" -o "$f" 2>/dev/null; sz=--size=${FZF_PREVIEW_COLUMNS}x${FZF_PREVIEW_LINES}; chafa CHAFA_OPTS $sz "$f" 2>/dev/null || chafa -f symbols --symbols block $sz "$f" 2>/dev/null || echo; fi
  """ |> String.trim()

  @poster_cache_max_age_s 30 * 24 * 3600

  defp prune_posters do
    dir = Path.join(System.tmp_dir!(), "laev-posters")
    cutoff = System.os_time(:second) - @poster_cache_max_age_s

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            path = Path.join(dir, name),
            {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
            mtime < cutoff do
          File.rm(path)
        end

        :ok

      _ ->
        :ok
    end
  end

  # Inside fzf's preview pipe chafa can't auto-detect terminal graphics, so
  # it silently degrades to colored block characters. Force the pixel
  # protocol by terminal identity instead; block symbols only as last resort.
  # LAEV_POSTERS=ascii swaps the whole thing for colored ASCII art —
  # foreground glyphs only; =ascii-bg additionally paints cell backgrounds.
  defp poster_preview_script do
    term = System.get_env("TERM") || ""
    program = System.get_env("TERM_PROGRAM") || ""

    chafa_opts =
      cond do
        Config.posters() == "ascii" -> "-f symbols -c full --symbols ascii --fg-only"
        Config.posters() == "ascii-bg" -> "-f symbols -c full --symbols ascii"
        String.contains?(term, "foot") -> "-f sixels"
        String.contains?(term, "kitty") or String.contains?(term, "ghostty") -> "-f kitty"
        program in ["ghostty", "kitty", "WezTerm"] -> "-f kitty"
        program == "iTerm.app" or System.get_env("LC_TERMINAL") == "iTerm2" -> "-f iterm"
        true -> "-f symbols --symbols block"
      end

    String.replace(@poster_preview, "CHAFA_OPTS", chafa_opts)
  end

  # Poster pane sizing: scales with the live terminal (measured per picker,
  # so resizing between menus just works), and below a minimum size posters
  # are skipped entirely — a pane that small is clutter, not art.
  @poster_min_cols 80
  @poster_min_rows 14

  # Live-resize floor, in PANE cells (fzf's <N(hidden) threshold compares
  # the preview pane's own width, NOT the terminal's — measured empirically;
  # a terminal-sized threshold here collapses the pane on normal displays).
  @poster_min_pane 35

  defp posters_fit? do
    {rows, cols} = tty_size()
    cols >= @poster_min_cols and rows >= @poster_min_rows
  end

  # Pane share per terminal-width tier; ASCII art gets more cells than
  # pixels because it needs them to stay readable.
  defp poster_tiers do
    if Config.posters() in ["ascii", "ascii-bg"], do: {50, 44, 38}, else: {42, 36, 30}
  end

  defp poster_width do
    {_rows, cols} = tty_size()
    {wide, mid, narrow} = poster_tiers()

    cond do
      cols >= 160 -> wide
      cols >= 120 -> mid
      true -> narrow
    end
  end

  # Live resize: Erlang spawns port children into their own session with no
  # controlling terminal, so fzf never receives SIGWINCH — it can't notice a
  # resize on its own (its `resize` event never fires under laev). The
  # escript, which does stay on the tty, polls the size instead and pushes a
  # recomputed layout + preview refresh into fzf over its --listen HTTP API.
  defp start_resize_watcher(port_file, api_key, mode, marker) do
    spawn(fn ->
      case await_fzf_port(port_file, 50) do
        nil -> :ok
        port -> watch_resize(port, api_key, tty_size(), mode, marker)
      end
    end)
  end

  # fzf picks a random port (--listen 0) and tells us via the start bind.
  defp await_fzf_port(_file, 0), do: nil

  defp await_fzf_port(file, tries) do
    with {:ok, contents} <- File.read(file),
         {port, _} <- Integer.parse(String.trim(contents)) do
      port
    else
      _ ->
        Process.sleep(100)
        await_fzf_port(file, tries - 1)
    end
  end

  defp watch_resize(port, api_key, last_size, mode, marker) do
    Process.sleep(300)
    size = tty_size()

    if size != last_size do
      case mode do
        # poster pickers: re-measure, recompute pane tier, re-render chafa
        :preview ->
          push_poster_layout(port, api_key)

        # plain pickers: a clear-screen makes fzf re-measure and reflow
        :reflow ->
          post_fzf(port, api_key, "clear-screen")

        # static-content screens: bail out of fzf so the caller rebuilds
        # the whole screen (banner/panel/grid) at the new size
        :abort ->
          File.touch!(marker)
          post_fzf(port, api_key, "abort")
      end
    end

    watch_resize(port, api_key, size, mode, marker)
  end

  # Two pushes: clear-screen makes fzf re-measure the terminal (it renders
  # at the stale size otherwise), then — once that redraw has landed — the
  # recomputed pane layout plus a preview re-render at the true new size.
  defp push_poster_layout(port, api_key) do
    post_fzf(port, api_key, "clear-screen")
    Process.sleep(150)

    post_fzf(
      port,
      api_key,
      "change-preview-window(right,#{poster_width()}%,border-left," <>
        "<#{@poster_min_pane}(hidden))+refresh-preview"
    )
  end

  defp post_fzf(port, api_key, command) do
    Req.post("http://127.0.0.1:#{port}",
      body: command,
      headers: [{"x-api-key", api_key}],
      retry: false,
      receive_timeout: 2_000
    )

    :ok
  rescue
    _ -> :ok
  end

  # Rows/columns of the terminal fzf will draw on. Must be asked in-process:
  # System.cmd children are spawned without a controlling terminal, so
  # `stty size </dev/tty` fails there even when laev itself is at one.
  defp tty_size do
    case {:io.rows(), :io.columns()} do
      {{:ok, rows}, {:ok, cols}} when rows > 0 and cols > 0 -> {rows, cols}
      _ -> {24, 80}
    end
  end

  defp pick_fzf(items, describe, header, preview, initial \\ nil, expect \\ [], resize \\ :reflow) do
    expect_arg = if expect == [], do: "", else: ~s(--expect=#{Enum.join(expect, ",")} )
    # fzf positions are 1-based; pos(1) is where it starts anyway. --sync
    # is required with start:pos — without it the jump races the async list
    # load and silently lands on row 1.
    pos = if initial && initial > 0, do: "+pos(#{initial + 1})", else: ""
    sync = if pos == "", do: "", else: "--sync "

    preview? =
      preview != nil and Config.posters() != "off" and
        System.find_executable("chafa") != nil and posters_fit?()
    if preview?, do: prune_posters()

    list =
      items
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {item, i} ->
        if preview?,
          do: "#{i}\t#{preview.(item) || "-"}\t#{describe.(item)}",
          else: "#{i}\t#{describe.(item)}"
      end)

    path = Path.join(System.tmp_dir!(), "laev-fzf-#{System.os_time(:millisecond)}")
    File.write!(path, list)
    port_file = path <> "-port"

    fzf =
      if preview? do
        # No --height: fullscreen on the alternate screen. An adaptive height
        # (~N%) would cap the window — and thus the poster, which keeps its
        # 2:3 aspect and is height-bound — at the list length.
        # The port file path is baked in literally: fzf runs binds in its own
        # $SHELL, where the outer sh's positional args don't exist.
        ~s(fzf --ansi --delimiter='\t' --with-nth=3.. --no-multi --reverse ) <> sync <> expect_arg <>
          ~s(--header="$2" ) <>
          ~s[--preview-window='right,#{poster_width()}%,border-left,<#{@poster_min_pane}(hidden)' ] <>
          ~s[--listen 0 --bind 'start:execute-silent(echo "$FZF_PORT" > #{port_file})#{pos}' ] <>
          ~s(--preview '#{poster_preview_script()}' < "$1")
      else
        ~s(fzf --ansi --delimiter='\t' --with-nth=2.. --no-multi --reverse --height=~60% ) <>
          sync <> expect_arg <>
          ~s[--listen 0 --bind 'start:execute-silent(echo "$FZF_PORT" > #{port_file})#{pos}' ] <>
          ~s(--header="$2" < "$1")
      end

    api_key = Base.encode16(:crypto.strong_rand_bytes(12))
    marker = path <> "-resized"
    mode = if preview?, do: :preview, else: resize
    watcher = start_resize_watcher(port_file, api_key, mode, marker)

    try do
      # fzf draws its UI on /dev/tty, reads the list from the redirected file,
      # and prints the chosen line on stdout — safe to run under System.cmd.
      case System.cmd("sh", ["-c", fzf, "sh", path, header],
             env: [{"FZF_API_KEY", api_key}]
           ) do
        {out, 0} ->
          {key, line} =
            if expect == [] do
              {nil, out}
            else
              # --expect prints the pressed key on its own line (empty for
              # plain enter), then the selection.
              case String.split(out, "\n", parts: 2) do
                [k, rest] -> {if(k == "", do: nil, else: k), rest}
                [only] -> {nil, only}
              end
            end

          {i, _} = line |> String.trim() |> Integer.parse()
          item = Enum.at(items, i)
          if expect == [], do: item, else: {key, item}

        {_, _cancelled} ->
          # An abort triggered by the resize watcher (marker present) is
          # not the user pressing esc — report it so the caller re-renders.
          if File.exists?(marker) do
            File.rm(marker)
            :resized
          else
            nil
          end
      end
    after
      if watcher, do: Process.exit(watcher, :kill)
      File.rm(path)
      File.rm(port_file)
      File.rm(marker)
    end
  end

  defp pick_number(items, describe, header, expect \\ []) do
    items
    |> Enum.with_index(1)
    |> Enum.each(fn {item, i} ->
      IO.puts(String.pad_leading("#{i}", 3) <> ". " <> describe.(item))
    end)

    case IO.gets("#{header} (number, empty to quit) ") do
      :eof ->
        nil

      line ->
        case Integer.parse(String.trim(line)) do
          {n, ""} when n >= 1 and n <= length(items) ->
            item = Enum.at(items, n - 1)
            if expect == [], do: item, else: {nil, item}

          _ ->
            nil
        end
    end
  end

  # Everything that decides trust leads in fixed-width columns, so the eye
  # never has to parse release names:
  #   ★ 4K    15.9GB  CAM  1322s  RD  Name…  [h265 · …]
  # seeders "—" = library/cached copies (no swarm involved, count unknown);
  # RD/TB = which debrid provider serves this stream (probed rows only).
  defp describe(s), do: describe(s, nil)

  defp describe(s, stream) do
    # ⚡ is a double-width glyph in most terminals; ★ is single-width — pad
    # so every prefix occupies 3 terminal cells and the columns line up.
    prefix =
      case Map.get(s, :cached) do
        :library -> "★  "
        true -> "⚡ "
        _ -> "   "
      end

    res =
      case s.resolution do
        "2160p" -> "4K"
        nil -> "?"
        other -> other
      end

    size = String.replace(s.size_human || "?", " ", "")
    lang = Map.get(s, :lang)
    cam? = s.source == "CAM"
    # Library/cached copies aren't "0 seeders" — they're already stored on
    # the debrid side, the safest thing on the list: ✓ instead of a count.
    seeders =
      cond do
        s.seeders && s.seeders > 0 -> "#{s.seeders}s"
        Map.get(s, :cached) in [:library, true] -> "✓"
        true -> "0s"
      end

    debrid =
      case stream && Map.get(stream, :provider) do
        :torbox -> "TB"
        :rd -> "RD"
        _ -> if Map.get(s, :cached) in [:library, true], do: "RD", else: ""
      end

    # BluRay/WEB/HDTV granularity stays in the details ("HD" alone doesn't
    # say remux vs webrip); CAM there would just repeat the column.
    details =
      [s.codec, s.audio, !cam? && s.source, Map.get(s, :langs) in [nil, []] && lang && "lang:#{lang}", Map.get(s, :provider)]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" · ")

    langs = Map.get(s, :langs) || []
    lang_suffix = if langs == [], do: "", else: "  " <> Enum.join(langs, "\u00b7")

    prefix <>
      String.pad_trailing(res, 6) <>
      String.pad_trailing(size, 9) <>
      String.pad_trailing(if(cam?, do: "CAM", else: "HD"), 4) <>
      String.pad_trailing(seeders, 6) <>
      String.pad_trailing(debrid, 3) <>
      truncate(s.name, 52) <> lang_suffix <> "  [#{details}]"
  end

  defp truncate(name, max) do
    if String.length(name) > max, do: String.slice(name, 0, max - 1) <> "…", else: name
  end

  # ── resolve / play ────────────────────────────────────────────────

  defp resolve(argv) do
    {magnet, opts} = magnet_args(argv, "resolve")

    case Providers.resolve_magnet(magnet, opts) do
      {:ok, stream} -> IO.puts(Jason.encode!(stream))
      {:error, reason} -> die_resolve(reason)
    end
  end

  defp play(argv) do
    {target, opts} = magnet_args(argv, "play")

    url =
      case target do
        "magnet:" <> _ ->
          case Providers.resolve_magnet(target, opts) do
            {:ok, stream} -> stream.url
            {:error, reason} -> die_resolve(reason)
          end

        "http" <> _ ->
          target

        other ->
          die("play needs a magnet link or URL, got: #{String.slice(other, 0, 40)}")
      end

    Player.open(:mpv, url)
    IO.puts(Jason.encode!(%{playing: url}))
  end

  defp magnet_args(argv, cmd) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [season: :integer, episode: :integer])

    check_invalid(invalid)

    unless Providers.any_configured?() do
      die("no debrid provider configured (RD_TOKEN or TORBOX_API_KEY) — run: laev setup")
    end

    case args do
      [target] -> {target, Keyword.take(opts, [:season, :episode])}
      _ -> die("#{cmd} needs exactly one magnet link (quote it!)")
    end
  end

  defp die_resolve({:not_cached, status, progress}) do
    die(%{error: "not cached on Real-Debrid", status: status, progress: progress})
  end

  defp die_resolve({:rd, 401, _}), do: die(rd_auth_error())
  defp die_resolve({:rd, 401}), do: die(rd_auth_error())

  defp die_resolve(reason), do: die("resolve failed: #{inspect(reason)}")

  # ── config ────────────────────────────────────────────────────────

  # `laev colors` — prints the raw terminal palette query + what laev derived,
  # so a theme-aware-logo issue can be diagnosed on the real terminal.
  defp debug_colors do
    cfg = config_palette()
    osc = if map_size(cfg) >= 2, do: %{}, else: query_palette()
    palette = Map.merge(osc, cfg)

    source =
      cond do
        logo_override() -> "LAEV_LOGO_COLORS override"
        map_size(cfg) >= 2 -> "terminal config file"
        map_size(osc) >= 2 -> "live OSC-4 query"
        true -> "fallback (red to gold)"
      end

    IO.puts(:stderr, "palette source: #{source} (#{map_size(palette)} colors)")

    for {i, {r, g, b}} <- Enum.sort(palette) do
      IO.puts(:stderr, "  color #{i}: rgb(#{r},#{g},#{b}) sat=#{Float.round(saturation({r, g, b}), 2)}")
    end

    case ramp_anchors() do
      {{r0, g0, b0}, {r1, g1, b1}} ->
        IO.puts(:stderr, "logo gradient: rgb(#{r0},#{g0},#{b0}) -> rgb(#{r1},#{g1},#{b1})")
    end

    if map_size(palette) < 2 and logo_override() == nil do
      IO.puts(:stderr, "\n(could not read the theme palette — set " <>
        "LAEV_LOGO_COLORS to two hex colors to pick the gradient manually.)")
    end
  end

  # ── MyAnimeList ───────────────────────────────────────────────────

  defp mal(["login" | _]) do
    unless Laev.MAL.configured?() do
      die("MAL_CLIENT_ID is not set — the app owner configures it in #{Config.path()}")
    end

    unless tty?(), do: die("mal login is interactive — run it at a terminal")

    IO.puts(:stderr, "opening MyAnimeList in your browser — approve access, then come back…")
    IO.puts(:stderr, IO.ANSI.format([:faint, "(redirect: #{Laev.MAL.redirect_uri()})", :reset]))

    case Laev.MAL.login(&browser_open/1) do
      {:ok, user} ->
        IO.puts(:stderr, IO.ANSI.format([:green, "✓ linked to MyAnimeList as #{user}", :reset]))
        IO.puts(:stderr, "anime you watch will now scrobble to your list automatically.")

      {:error, reason} ->
        die("MAL login failed: #{inspect(reason)}")
    end
  end

  defp mal(["logout" | _]) do
    Laev.MAL.logout()
    IO.puts(:stderr, "unlinked from MyAnimeList.")
  end

  defp mal(_) do
    cond do
      not Laev.MAL.configured?() ->
        IO.puts(:stderr, "MyAnimeList: not configured (owner sets MAL_CLIENT_ID). ")

      Laev.MAL.authenticated?() ->
        IO.puts(:stderr, "MyAnimeList: linked as #{Laev.MAL.username() || "?"} — laev mal logout to unlink")

      true ->
        IO.puts(:stderr, "MyAnimeList: not linked — run: laev mal login")
    end
  end

  # Fire-and-forget scrobbler: watches the position file for THIS episode and,
  # the moment it's marked watched (85%/eof), pushes progress to MAL. Exits
  # when it scrobbles, or when mpv is gone (episode abandoned early). Anime +
  # logged-in only. Never blocks the menu.
  defp start_mal_scrobbler(ctx) do
    if ctx && ctx[:anime] && is_integer(ctx.episode) && Laev.MAL.authenticated?() &&
         Config.mal_scrobble?() do
      spawn(fn -> mal_scrobble_loop(ctx, System.os_time(:second)) end)
    end

    :ok
  end

  defp mal_scrobble_loop(ctx, started) do
    Process.sleep(5_000)

    cond do
      Laev.Position.finished?(ctx) ->
        scrobble_mal(ctx)

      mal_scrobble_stale?(ctx, started) ->
        :ok

      true ->
        mal_scrobble_loop(ctx, started)
    end
  end

  defp mal_scrobble_stale?(ctx, started) do
    now = System.os_time(:second)

    case Laev.Position.last_saved_at(ctx) do
      nil -> now - started > 90
      mtime -> now - mtime > 30
    end
  end

  # Companion to the MAL scrobbler, but for sync: waits until this session's
  # playback is over — the episode finished, or the position went stale (mpv
  # closed mid-episode) — then pushes the final position + watched flag to
  # the endpoint. Dies silently with the CLI process; the exit-time sync and
  # the next launch's startup sync are the safety nets.
  defp start_sync_watcher(ctx) do
    if ctx && Laev.Sync.enabled?() and (Laev.Sync.auto?() or Laev.Sync.live?()) do
      spawn(fn -> sync_watch_loop(ctx, System.os_time(:second)) end)
    end

    :ok
  end

  defp sync_watch_loop(ctx, started) do
    Process.sleep(5_000)

    cond do
      Laev.Position.finished?(ctx) or mal_scrobble_stale?(ctx, started) ->
        if Laev.Sync.auto?(),
          do: Laev.Sync.sync_quiet("watched"),
          else: Laev.Sync.live_push()

      true ->
        sync_watch_loop(ctx, started)
    end
  end

  defp scrobble_mal(ctx) do
    with mal_id when is_integer(mal_id) <- mal_id_for(ctx) do
      total = anime_episode_count(ctx[:search_title] || ctx.title)

      case Laev.MAL.set_progress(mal_id, ctx.episode, total) do
        :ok -> IO.puts(:stderr, IO.ANSI.format([:faint, "  ↑ MAL: #{ctx.title} ep #{ctx.episode}", :reset]))
        _ -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp rate_on_mal(ctx) do
    with mal_id when is_integer(mal_id) <- mal_id_for(ctx),
         line when is_binary(line) <- IO.gets("  score on MyAnimeList (1–10, enter to skip): "),
         {score, _} <- Integer.parse(String.trim(line)),
         true <- score in 1..10 do
      case Laev.MAL.rate(mal_id, score) do
        :ok -> IO.puts(:stderr, IO.ANSI.format([:green, "  ✓ rated #{score}/10 on MAL", :reset]))
        _ -> IO.puts(:stderr, "  couldn't submit the rating")
      end
    else
      _ -> :ok
    end
  end

  # Resolve a MAL id for an anime ctx from its title (AniList idMal), cached.
  defp mal_id_for(ctx) do
    title = ctx[:search_title] || ctx[:title]
    key = {:mal_id, title}

    case Process.get(key, :miss) do
      :miss ->
        id = anilist_mal_id(title)
        Process.put(key, id)
        id

      cached ->
        cached
    end
  end

  defp anilist_mal_id(nil), do: nil

  defp anilist_mal_id(title) do
    query =
      "query($s:String){Page(perPage:8){media(search:$s,type:ANIME)" <>
        "{idMal popularity synonyms title{romaji english native}}}}"

    case Req.post("https://graphql.anilist.co",
           json: %{query: query, variables: %{s: title}},
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"Page" => %{"media" => list}}}}} when is_list(list) ->
        best_anilist_match(list, title)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # AniList's own ranking puts spinoffs first often enough to matter: searching
  # Frieren's English title answers with a 12-episode ONA short (10k
  # popularity) ahead of the series itself (480k), which would then be the show
  # episodes scrobble against. So prefer a candidate that actually calls itself
  # what was asked for, and only fall back to the most popular — popularity
  # alone would answer "Attack on Titan Season 2" with season 1.
  defp best_anilist_match(list, title) do
    wanted = normalize_title(title)
    usable = Enum.filter(list, &is_integer(&1["idMal"]))

    exact =
      Enum.filter(usable, fn m ->
        names = [m["title"]["romaji"], m["title"]["english"], m["title"]["native"] | m["synonyms"] || []]
        Enum.any?(names, &(normalize_title(&1) == wanted))
      end)

    case (exact == [] && usable) || exact do
      [] -> nil
      pool -> pool |> Enum.max_by(&(&1["popularity"] || 0)) |> Map.get("idMal")
    end
  end

  # Loose enough that curly apostrophes, colons and spacing don't decide a
  # match ("Frieren: Beyond Journey's End" vs "Frieren: Beyond Journey’s End").
  defp normalize_title(nil), do: nil

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[\x{2019}\x{02BC}'`]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp config do
    IO.puts(Jason.encode!(%{config_file: Config.path(), keys: Config.status()}))
  end

  # ── setup (interactive first-run wizard) ──────────────────────────

  defp setup do
    unless tty?(), do: die("setup is interactive — run it at a terminal")

    IO.puts(:stderr, IO.ANSI.format(["\n  🍿 ", :bright, "laev setup", :reset, "\n"]))

    options = [
      {:fresh, "🔑 New setup — enter my API keys"},
      {:restore, "⇄  I already have a laev key from another device"}
    ]

    case pick(options, &elem(&1, 1), "enter selects · esc backs out") do
      {:restore, _} -> restore_from_laev_key()
      {:fresh, _} -> fresh_setup()
      _ -> cancel_setup()
    end
  end

  # Leaving the wizard. Backing out to the menu is only useful if laev can
  # actually run — with no keys the menu sends you straight back here, so a
  # first-run cancel has to end the session instead of looping.
  defp cancel_setup do
    IO.puts(:stderr, IO.ANSI.format([:faint, "\n  setup cancelled.\n", :reset]))

    if Providers.any_configured?() and Tmdb.configured?(),
      do: back(),
      else: System.halt(0)
  end

  # Esc can't interrupt IO.gets — the terminal is in line mode, so it just
  # lands in the buffer as \e and the line comes back with escape sequences in
  # it. Reading that as "cancel" is what the keypress meant, and stops the
  # wizard from trying to validate the gibberish and asking again.
  defp cancelled?(line) when is_binary(line), do: String.contains?(line, "\e")
  defp cancelled?(_), do: false

  # The one-paste path: a laev key carries the endpoint's contents, so the
  # machine ends up configured exactly like the one the key came from — keys
  # included, when that machine had key-carrying on. If it didn't, there is
  # nothing to restore beyond the library, so fall through to entering keys.
  defp restore_from_laev_key do
    IO.puts(
      :stderr,
      "\n  On your other device: Settings → 🔄 Cross-device sync → show my laev key.\n"
    )

    entered = IO.gets("  laev key: ") |> to_string()
    if cancelled?(entered), do: cancel_setup()
    key = String.trim(entered)

    if key == "" do
      IO.puts(:stderr, IO.ANSI.format([:faint, "  nothing pasted — setting up from scratch instead.\n", :reset]))
      fresh_setup()
    else
      typed = IO.gets("  endpoint [#{@hosted_sync_url}]: ") |> to_string()
      if cancelled?(typed), do: cancel_setup()

      url =
        case String.trim(typed) do
          "" -> @hosted_sync_url
          entered -> entered
        end

      write_config_keys([
        {"LAEV_SYNC_URL", url},
        {"LAEV_SYNC_TOKEN", key},
        {"LAEV_SYNC_KEYS", "on"},
        {"LAEV_SYNC_AUTO", "on"}
      ])

      Config.load()
      IO.puts(:stderr, "\n  pulling…")

      case Laev.Sync.sync() do
        {:ok, summary} ->
          Enum.each(sync_summary_lines(summary), &IO.puts(:stderr, "  " <> &1))
          finish_restore()

        {:error, reason} ->
          IO.puts(:stderr, IO.ANSI.format([:red, "  ✗ #{inspect(reason)}\n", :reset]))
          IO.puts(:stderr, "  Setting up by hand instead — the key stays saved, so sync\n  will pick it up once the server is reachable.\n")
          fresh_setup()

        :disabled ->
          fresh_setup()
      end
    end
  end

  defp finish_restore do
    if Providers.any_configured?() and Tmdb.configured?() do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          :green,
          "\n  ✓ restored — your keys and your library came across. Nothing else to enter.\n",
          :reset
        ])
      )

      IO.puts(:stderr, "  all set — run: laev\n")
    else
      IO.puts(
        :stderr,
        IO.ANSI.format([
          :yellow,
          "\n  Your library came across, but no API keys were stored with that key.\n",
          :reset,
          "  (Turn on “carry my API keys” on the other device to include them.)\n"
        ])
      )

      fresh_setup()
    end
  end

  defp fresh_setup do
    rd =
      prompt_key(
        "Real-Debrid API token",
        "https://real-debrid.com/apitoken",
        Application.get_env(:laev_app, :rd_token),
        &Laev.Doctor.check_rd/1
      )

    tmdb =
      prompt_key(
        "TMDB API key",
        "https://www.themoviedb.org/settings/api",
        Application.get_env(:laev_app, :tmdb_key),
        &Laev.Doctor.check_tmdb/1
      )

    torbox =
      prompt_optional_key(
        "TorBox API key (optional — second debrid provider)",
        "https://torbox.app/settings",
        Application.get_env(:laev_app, :torbox_api_key),
        &Laev.Doctor.check_torbox/1
      )

    keys = [{"RD_TOKEN", rd}, {"TMDB_API_KEY", tmdb}] ++ if(torbox, do: [{"TORBOX_API_KEY", torbox}], else: [])
    write_config_keys(keys)
    Config.load()

    IO.puts(:stderr, "")

    for {bin, why} <- [{"mpv", "required — plays the streams"}, {"fzf", "nicer pickers"}, {"chafa", "poster previews"}] do
      mark = if System.find_executable(bin), do: IO.ANSI.format([:green, "  ✓ "]), else: IO.ANSI.format([:red, "  ✗ "])
      IO.puts(:stderr, [mark, bin, IO.ANSI.format([:faint, " — #{why}", :reset])])
    end

    IO.puts(
      :stderr,
      "\n  saved to #{Config.path()}\n  optional extras (subtitles, Jackett, Jimaku) live in the same file.\n  all set — run: laev\n"
    )
  end

  # Ask for one key, validate it live against the real service, loop on
  # rejection. An existing key is shown masked (stars + its last characters)
  # with an explicit enter-to-keep, so a rerun never forces re-entry.
  defp prompt_key(name, url, existing, validate) do
    IO.puts(:stderr, IO.ANSI.format(["  ", :bright, name, :reset, :faint, "  #{url}", :reset]))

    if existing do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          "  current: ",
          :yellow,
          mask(existing),
          :reset,
          :faint,
          "  — press enter to keep it, or paste a new key",
          :reset
        ])
      )
    end

    case IO.gets("  > ") do
      :eof ->
        cancel_setup()

      line when is_binary(line) and byte_size(line) > 0 ->
        if cancelled?(line), do: cancel_setup()

        case {String.trim(line), existing} do
          {"", nil} ->
            IO.puts(:stderr, IO.ANSI.format([:yellow, "  a key is required\n", :reset]))
            prompt_key(name, url, existing, validate)

          {"", key} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  ✓ keeping #{mask(key)}\n", :reset]))
            key

          {key, _} ->
            IO.write(:stderr, "  checking… ")

            case validate.(key) do
              {:ok, detail} ->
                IO.puts(:stderr, IO.ANSI.format([:green, "✓ ", :reset, detail, "\n"]))
                key

              {:error, reason} ->
                IO.puts(:stderr, IO.ANSI.format([:red, "✗ #{reason}", :reset, " — try again\n"]))
                prompt_key(name, url, existing, validate)
            end
        end
    end
  end

  # Like prompt_key/4 but skippable: enter with nothing configured moves on
  # (returns nil), and a rejected key can still be skipped with enter.
  defp prompt_optional_key(name, url, existing, validate) do
    IO.puts(:stderr, IO.ANSI.format(["  ", :bright, name, :reset, :faint, "  #{url}", :reset]))

    if existing do
      IO.puts(
        :stderr,
        IO.ANSI.format([
          "  current: ",
          :yellow,
          mask(existing),
          :reset,
          :faint,
          "  — press enter to keep it, or paste a new key",
          :reset
        ])
      )
    else
      IO.puts(:stderr, IO.ANSI.format([:faint, "  press enter to skip", :reset]))
    end

    case IO.gets("  > ") do
      :eof ->
        existing

      line when is_binary(line) and byte_size(line) > 0 ->
        if cancelled?(line), do: cancel_setup()

        case {String.trim(line), existing} do
          {"", nil} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  skipped\n", :reset]))
            nil

          {"", key} ->
            IO.puts(:stderr, IO.ANSI.format([:faint, "  ✓ keeping #{mask(key)}\n", :reset]))
            key

          {key, _} ->
            IO.write(:stderr, "  checking… ")

            case validate.(key) do
              {:ok, detail} ->
                IO.puts(:stderr, IO.ANSI.format([:green, "✓ ", :reset, detail, "\n"]))
                key

              {:error, reason} ->
                IO.puts(
                  :stderr,
                  IO.ANSI.format([:red, "✗ #{reason}", :reset, " — try again (enter skips)\n"])
                )

                prompt_optional_key(name, url, existing, validate)
            end
        end
    end
  end

  # Stars with the last few characters visible — enough to recognize which
  # key it is without exposing it.
  defp mask(key) when byte_size(key) > 8,
    do: String.duplicate("*", 12) <> binary_part(key, byte_size(key) - 4, 4)

  defp mask(_key), do: "************"

  # Update KEY=VALUE lines in the config file in place (comments and other
  # keys untouched); append keys that aren't there yet. Mode 600 — it holds
  # secrets.
  defp write_config_keys(pairs), do: Config.write(pairs)

  # ── doctor (health checks) ────────────────────────────────────────

  defp doctor do
    IO.puts(:stderr, "\nlaev doctor — checking everything laev depends on…\n")
    {results, healthy?} = Laev.Doctor.run()

    for section <- [:binaries, :services] do
      IO.puts(:stderr, IO.ANSI.format([:bright, "  #{section}", :reset]))

      for {^section, name, status, detail} <- results do
        {mark, color} =
          case status do
            :ok -> {"✓", :green}
            :skip -> {"–", :faint}
            :error -> {"✗", :red}
          end

        IO.puts(
          :stderr,
          IO.ANSI.format([
            color,
            "    #{mark} ",
            :reset,
            String.pad_trailing(name, 15),
            :faint,
            detail,
            :reset
          ])
        )
      end

      IO.puts(:stderr, "")
    end

    {rows, cols} = tty_size()

    IO.puts(
      :stderr,
      IO.ANSI.format([
        :bright,
        "  terminal",
        :reset,
        "\n    #{cols}×#{rows} · posters: #{Config.posters()} · skip: #{Config.skip()} · lang: #{Config.lang()}\n"
      ])
    )

    if healthy? do
      IO.puts(:stderr, IO.ANSI.format([:green, "  all good — happy watching\n", :reset]))
    else
      IO.puts(:stderr, IO.ANSI.format([:red, "  something's broken — fix the ✗ lines above\n", :reset]))
      System.halt(1)
    end
  end

  # ── update (self-replace the standalone binary) ───────────────────

  defp update do
    bin = System.get_env("__BURRITO_BIN_PATH")

    unless bin do
      die("self-update only works for the standalone binary — " <>
        "from a source checkout: git pull && mix escript.build")
    end

    current = Application.spec(:laev_app, :vsn) |> to_string()
    IO.puts(:stderr, "current: v#{current} — checking the latest release…")

    latest =
      Laev.UpdateCheck.fetch_latest() ||
        die("couldn't reach GitHub releases — try again later")

    if Version.compare(current, latest) != :lt do
      IO.puts(:stderr, "already up to date")
      IO.puts(Jason.encode!(%{updated: false, version: current}))
      System.halt(0)
    end

    asset =
      Laev.UpdateCheck.asset_name() ||
        die("no prebuilt binary for this platform — update from source")

    IO.puts(:stderr, "downloading v#{latest} (#{asset})…")

    body =
      case Req.get(Laev.UpdateCheck.download_url(asset),
             receive_timeout: 120_000,
             decode_body: false
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 1_000_000 ->
          body

        {:ok, %{status: status}} ->
          die("download failed (HTTP #{status})")

        {:error, reason} ->
          die("download failed: #{inspect(reason)}")
      end

    # Stage next to the target, then rename — atomic on the same filesystem,
    # so a failed download can never leave a half-written laev behind.
    staged = bin <> ".new"

    with :ok <- File.write(staged, body),
         :ok <- File.chmod(staged, 0o755),
         :ok <- File.rename(staged, bin) do
      IO.puts(:stderr, "✔ updated v#{current} → v#{latest} (#{bin})")
      IO.puts(Jason.encode!(%{updated: true, from: current, to: latest}))
    else
      {:error, reason} ->
        File.rm(staged)
        die("couldn't replace #{bin} (#{inspect(reason)}) — is that location writable?")
    end
  end

  # ── plumbing ──────────────────────────────────────────────────────

  defp check_invalid([]), do: :ok
  defp check_invalid(invalid), do: die("bad options: #{inspect(invalid)}")

  defp die(error) when is_map(error) do
    IO.puts(:stderr, Jason.encode!(error))
    System.halt(1)
  end

  defp die(message), do: die(%{error: message})

  defp usage(exit_code) do
    IO.puts(:stderr, """
    laev — search sources, resolve via your debrid account, play in mpv

    usage:
      laev                   open the interactive menu (Continue / Featured / Search)
      laev watch "<title>"   [--auto] [--binge] [--raw] [--backend apibay|nyaa|anime] [--limit N]
      laev download "<title>" same flow as watch, but saves the file (LAEV_DOWNLOAD_DIR)
      laev featured          browse what's trending on TMDB and pick something
      laev calendar          when your watchlist's episodes and movies drop
      laev resume            instantly resume the last thing you watched
      laev continue          pick from your watch history
      laev search "<query>"  [--backend apibay|nyaa|anime] [--limit N] [--json|--pretty]
      laev resolve <magnet>  [--season N] [--episode N]
      laev play <magnet|url> [--season N] [--episode N]
      laev setup             interactive first-run wizard: keys in, validated live
      laev doctor            check binaries, keys, and every service laev talks to
      laev config
      laev update            self-update the standalone binary to the latest release
      laev mal [login|logout] link MyAnimeList to scrobble anime progress

    watch is interactive: pick the title (TMDB), for shows the season and
    episode, then a source — it resolves on your debrid account and plays
    in mpv. --raw skips TMDB and searches torrents by text directly.
    search prints a readable list at a terminal and JSON when piped.
    Config: #{Config.path()}
    """)

    System.halt(exit_code)
  end
end
