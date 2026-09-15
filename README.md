# Laev

A standalone command-line app for watching movies and shows through your own
debrid account — no browser, no Electron, no background app. Type a title,
pick an episode and a source, and **mpv** opens playing the stream. That's it.

```
$ laev watch "in the grey"
what to watch? (12 results, all shown)
> In the Grey (2026) · movie · ★7.1
  ...
checking 8 sources (14 more unchecked)…
  ✓ In.the.Grey.2026.2160p.WEB-DL ...
which source? (all checked + playable)
> ★ In.the.Grey.2026.2160p.WEB-DL  [18.2 GB · 2160p ...]
playing in mpv: In.the.Grey.2026.2160p.WEB-DL.mkv
```

Laev is a **single binary** — not a library, not a service, nothing to add to
a project. (Unrelated to the `kino` package on hex.pm, which is Livebook's
widget library.)

## What it does

- **Title-first search** via TMDB: movies and shows, season/episode pickers,
  spelling-variant matching ("gray" finds "Grey"), year hints
  (`laev watch "heat 1995"`). The search box remembers your last 20 searches —
  ↑↓ walks them into the search bar (highlighted in the list as you go), where
  you can fix a typo before running it; ctrl-d forgets an entry.
- **Only playable sources are offered.** Every source is actually resolved on
  your debrid provider before it reaches the picker — dead torrents, DMCA'd
  files, and 0-seeder stalls are filtered out with the reason shown.
  Known takedowns are remembered and skipped instantly.
- **Ranked like you'd want**: releases already in your debrid library first,
  provider-confirmed-cached next, then resolution tier with bigger files
  first. Releases in languages other than yours sink to the bottom
  (`LAEV_LANG`, default English; dual-audio stays).
- **Continue watching**: `laev continue` jumps back to the exact episode,
  source, **and second** you left off at — the position is checkpointed every
  5 seconds while mpv plays, so it survives player crashes and power loss.
  It's remembered per title/episode, not per stream, so switching to a
  different source resumes from the same spot.
- **Scriptable**: `laev search`/`resolve`/`play` emit JSON when piped, so the
  interactive flow is just one frontend — overlays and scripts are another.

## Install

The binaries are self-contained — no Erlang, no Elixir, nothing to add to a
project. You just need **mpv** for playback (`fzf` is optional but makes the
pickers much nicer).

**Linux (x86_64):**

```sh
sudo pacman -S --needed mpv fzf   # or your distro's equivalent
curl -Lo laev https://github.com/alexdont/laev/releases/latest/download/laev_linux_x86_64
chmod +x laev && mkdir -p ~/.local/bin && mv laev ~/.local/bin/
```

**Windows** — use WSL2 (the built-in Ubuntu console; Windows 11 or updated
Windows 10, so mpv opens as a regular window via WSLg). Then it's exactly the
Linux install:

```sh
sudo apt install -y mpv fzf chafa
curl -Lo laev https://github.com/alexdont/laev/releases/latest/download/laev_linux_x86_64
chmod +x laev && mkdir -p ~/.local/bin && mv laev ~/.local/bin/
```

**macOS (Apple Silicon)** — untested build, feedback welcome:

```sh
brew install mpv fzf
curl -Lo laev https://github.com/alexdont/laev/releases/latest/download/laev_macos_aarch64
chmod +x laev && mv laev /usr/local/bin/
```

**From source** (needs Elixir; zig + p7zip only for the standalone build):

```sh
mix deps.get
mix escript.build               # → ./laev (needs Erlang installed to run)
MIX_ENV=prod mix release laev   # → burrito_out/laev_* (self-contained)
```

## Configure

Run `laev setup` — an interactive wizard that asks for your two keys,
validates them live against the real services, and writes the config for
you. (`laev doctor` later checks every binary, key, and service laev talks
to, with latencies.)

Or put keys in `~/.config/laev/config` by hand (env vars with the same
names also work and take precedence):

```
# required — your Real-Debrid API token: https://real-debrid.com/apitoken
RD_TOKEN=...
# required for the title flow: https://www.themoviedb.org/settings/api
TMDB_API_KEY=...
# optional second debrid provider: https://torbox.app/settings
#TORBOX_API_KEY=...
# preferred audio language for ranking (dual/multi releases always rank normally)
LAEV_LANG=en
# poster previews: auto (sharp pixel graphics), ascii (colored ASCII art),
# ascii-bg (ASCII with painted backgrounds), off
LAEV_POSTERS=auto
# intro/credits skipping — detected via AniSkip (anime) + named chapters:
#   ask (default): a "Skip — hold TAB" button appears on the video, skip is your call
#   auto: skip immediately · off: disable (hold Tab = +85s works in ask/auto)
LAEV_SKIP=ask
# autoplay the next episode when one ends ("on" to enable — off by default;
# --binge or the post-play menu's autoplay entry do it per session)
LAEV_AUTOPLAY=off
# optional: scrobble anime to MyAnimeList (owner-provided app id; then `laev mal login`)
#MAL_CLIENT_ID=...
# optional: Jackett/Prowlarr (more indexers), OpenSubtitles, Jimaku
# optional: cross-device sync to a server you run (see "Sync across devices")
#LAEV_SYNC_URL=https://your-server.example/laev
#LAEV_SYNC_TOKEN=...
```

`laev config` shows which keys are set.

## Commands

| command | what it does |
| --- | --- |
| `laev watch "<title>"` | the whole flow: title → episode → source → mpv |
| `laev resume` | instantly resume the last thing you watched |
| `laev continue` | pick from your watch history |
| `laev search "<query>"` | list raw sources (JSON when piped) |
| `laev resolve <magnet>` | magnet → direct stream URL (JSON) |
| `laev play <magnet\|url>` | resolve and launch mpv directly |
| `laev setup` | first-run wizard: keys in, validated live |
| `laev doctor` | health-check binaries, keys, and services |
| `laev mal login` | link MyAnimeList (anime scrobbling) |
| `laev sync` | sync watch state now (`laev sync status` shows config) |
| `laev config` | show config status |

`laev watch --raw "<text>"` skips TMDB and searches indexers by text.

## Sync across devices (optional)

By default laev is **local-first**: your watchlist, history, resume points and
watched flags live only in `~/.laev` and never leave the machine. Nothing is
sent anywhere until you turn sync on.

Open **Settings → 🔌 Integrations → 🔄 Cross-device sync** and pick one:

- **📁 Local only** *(default)* — nothing leaves this machine.
- **☁ Laev hosted server** — point laev at the maintainer's endpoint (needs an
  access token). *(Only when a public server exists.)*
- **🖥 My own server** — a sync server you run yourself, for full control of
  your data.

Once on, laev pulls-merges-pushes on startup and after each episode (or run
`laev sync` manually). Merging is **last-write-wins per item with tombstones**,
so pins, un-pins, positions and watched flags from every device converge — pick
up on your laptop exactly where the phone left off. Your **API keys and
MyAnimeList login are never synced**, only user state.

### Running your own server

The server is deliberately tiny: it stores **one opaque JSON document per
access token** and exposes just `GET` (pull) and `PUT` (push, with an `ETag` /
`If-Match` guard). All the merge logic lives in laev, so the server never has
to understand the data.

It supports two storage backends behind the **exact same HTTP API** — pick
whichever you trust; laev can't tell the difference, and you can switch later
without touching any client:

- **Postgres** *(recommended if you already run one)* — a single table, e.g.
  `laev_sync(token text primary key, document jsonb, etag text, updated_at timestamptz)`.
- **Local files** — one JSON file per token under a data directory. No database
  needed; ideal for a single box.

Select the backend with an env var on the server (e.g. `LAEV_STORE=postgres`
+ `DATABASE_URL=…`, or `LAEV_STORE=file` + `LAEV_STORE_DIR=…`). Put it behind
HTTPS (a reverse proxy, Tailscale, or a Cloudflare Tunnel), then in laev set
the endpoint URL and a long random token.

## Notes

Laev ships no content and hosts nothing. It searches public indexers and
drives **your own** debrid subscription and API keys, the same way a Stremio
debrid addon does; takedown responses from the provider are respected and
remembered. Real-Debrid and TorBox are wired today, and the resolve
step sits behind a behaviour so AllDebrid/Premiumize can be added too.
