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
a project.

## What it does

- **Title-first search** via TMDB: movies and shows, season/episode pickers,
  spelling-variant matching ("gray" finds "Grey"), year hints
  (`laev watch "heat 1995"`). The search box remembers your last 100 searches —
  type a few letters to narrow them, then ↑↓ walks the matches into the search
  bar (completing to the full title, still editable); ctrl-d forgets an entry.
- **Anime by season.** Anime is published in quarters and talked about that way,
  so Featured → Anime asks which one: `airing now`, then `Fall 2026 · this
  season`, `Summer 2026`, `Spring 2026` and back. `⋯ earlier seasons` pages
  deeper — as far as anime television goes — and typing a year jumps to it. A
  season is its premiere quarter, the way every seasonal chart is built.
- **Franchises in one place.** Searching any film of a series offers the whole
  thing at the top of the results — every Alien, all of Middle-earth, the 207
  Marvel titles with Essentials / Everything / Prepare for Doomsday to choose
  between — in release order, with long-running shows listed a season at a time
  so they sit where they aired. Most series come straight from TMDB; the ones it
  groups badly are curated in `priv/franchises.json`. `ctrl-s` pins a whole list
  to Saved, not just a title. **Featured → Lists** browses every curated list with
  how much of each is behind you — `Animation · 230 titles · 134/230 watched` —
  which is the "have I seen all of these" question the lists exist to answer.
- **Animation** is one of them, and not a franchise: every animated feature the
  big studios have released, in release order, with tiers for Disney, Pixar,
  DreamWorks, Illumination, Sony, stop-motion (LAIKA and Aardman), Ghibli and
  everyone else. Ghibli needs the whole canon, so Nausicaä is added by hand —
  TMDB credits it to Topcraft, who made it two years before the studio existed,
  and files it under the name of the 1985 recut Miyazaki disowned. Generated from TMDB by `tools/build_animated.py` rather than typed —
  studio by studio, across the several company ids TMDB files each one's eras
  under, kept to released features by the runtime on the details endpoint (which
  is the only one that knows a 21-minute Madagascar special isn't a film).
- **Only playable sources are offered.** Every source is actually resolved on
  your debrid provider before it reaches the picker — dead torrents, DMCA'd
  files, and 0-seeder stalls are filtered out with the reason shown.
  Known takedowns are remembered and skipped instantly.
- **Ranked like you'd want**: releases already in your debrid library first,
  provider-confirmed-cached next, then resolution tier with bigger files
  first. Releases in languages other than yours sink to the bottom
  (`LAEV_LANG`, default English; dual-audio stays).
- **Real track languages, not filename guesses.** On Real-Debrid every
  probed source also reports the audio and subtitle tracks actually inside
  the file (`🔊ru·en 💬ru`), so a "1080p" release with five dubs shows them —
  and ranking uses those languages instead of whatever the name hints.
- **Watchlist** — everything you are in the middle of, shows and anime together,
  **most recently watched first**: open it, press enter twice, and you are back in
  last night's episode without touching an arrow key. Each row says how far in you
  are — `2/4 seasons watched`, or `7/10 episodes watched` inside a season, or
  `11/12 episodes` for anime. Below it, two sections behind their own chevrons:
  **caught up** (every season that exists is watched — you are waiting, not
  behind) and **on hold** (`ctrl-h`, for the things you got four episodes into and
  stopped). The home-screen count is only the first section, because being caught
  up or put down is not something left to do. A show marks itself *finished* only
  when it is watched through **and silent** — nothing aired for five years, at
  which point it is over by any reading. Anything newer waits in caught up
  however certain its ending looks, because a 2025 show between seasons is not
  finished and you shouldn't be made to forget it. TMDB's status is deliberately
  not consulted: it files most K-dramas as Ended the week their first run closes
  and keeps dead shows Returning for a decade — silence is the honest signal.
  Films and anime stay automatic, because playing a film to the end is finishing
  it by any definition, and an anime entry on MAL is one season whose last
  episode really is its end.
- **Saved** — the other list: titles you pressed `ctrl-s` on to watch later, with
  watched ones greyed and a count of what is left. Watchlist is what you *are*
  watching; Saved is what you *mean to*.
- **Continue watching**: `laev continue` jumps back to the exact episode,
  source, **and second** you left off at — the position is checkpointed every
  5 seconds while mpv plays, so it survives player crashes and power loss.
  It's remembered per title/episode, not per stream, so switching to a
  different source resumes from the same spot.
- **Scriptable**: `laev search`/`resolve`/`play` emit JSON when piped, so the
  interactive flow is just one frontend — overlays and scripts are another.

## Install

The binaries are self-contained — no Erlang, no Elixir, nothing to add to a
project. You just need **mpv** for playback; `fzf` makes the pickers much
nicer and **chafa** is what draws the poster previews (without it the poster
pane is simply absent — `laev doctor` says so).

**Linux (x86_64):**

```sh
sudo pacman -S --needed mpv fzf chafa   # or your distro's equivalent
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
brew install mpv fzf chafa
curl -Lo laev https://github.com/alexdont/laev/releases/latest/download/laev_macos_aarch64
chmod +x laev && mkdir -p ~/.local/bin && mv laev ~/.local/bin/
# macOS doesn't put ~/.local/bin on PATH — add it if `which laev` finds nothing:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh
```

Not `/usr/local/bin`: it's owned by root on macOS, so the move fails without
`sudo` — and installing it there with `sudo` leaves a root-owned binary that
`laev update`, which replaces the binary in place, then can't overwrite.

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
#   ask (default): a "Skip opening · hold TAB" button appears for a few seconds;
#     TAB keeps working for the whole window, the button just gets out of the way
#   auto: skip immediately · off: disable (hold Tab = +85s works in ask/auto)
LAEV_SKIP=ask
# play the best source instead of asking which one — on by default ("off" to
# always pick yourself); ⇄ try another source opens the full list either way
LAEV_AUTO_SOURCE=on
# the highest resolution to start automatically: 720p | 1080p | 4K | any.
# A ceiling on the pick, not on the search — every release is still found and
# listed, so a 4K you didn't want to start by itself is one keypress away
LAEV_MAX_RESOLUTION=1080p
# ...unless this is on, which drops higher releases before they're even checked
LAEV_STRICT_RESOLUTION=off
# autoplay the next episode when one ends ("on" to enable — off by default;
# --binge or the post-play menu's autoplay entry do it per session)
LAEV_AUTOPLAY=off
# optional: anime scrobbling, scores and list import on MyAnimeList
# (owner-provided app id; then `laev mal login`)
#MAL_CLIENT_ID=...
# optional: Jackett/Prowlarr (more indexers), OpenSubtitles, Jimaku
# optional: cross-device sync to a server you run (see "Sync across devices")
#LAEV_SYNC_URL=https://your-server.example/laev
#LAEV_SYNC_TOKEN=...
```

`laev config` shows which keys are set.

### Bringing a watch history in

`laev tmdb import` marks everything you have rated on TMDB as watched here —
including ratings you imported into TMDB from IMDb, which is the easiest way to
carry years of viewing across. Nobody rates a film they haven't seen, so a
rating is the one unambiguous record of having watched it.

It writes marks and nothing else: titles grey out in search, Featured and the
Saved, and the stats count them in the **off laev** bucket, where an assumed
runtime belongs. Positions you are partway through are left alone — a rating is
no reason to overwrite somebody's place in something. Run it as often as you
like; it only ever fills gaps.

**What counts as anime** is what MyAnimeList has an entry for, not what TMDB
calls Japanese. Tomb Raider King is a Korean webtoon animated by Japanese studios
and aired on Fuji TV, so TMDB files it as `ko`; testing the language alone sent
it down the live-action path, with no scrobbler, no MyAnimeList rating row, and
its marks under the TMDB show instead of the MAL entry — which is how one show
ended up on the Watchlist twice, as two half-finished rows. The cross-id list
already on disk knows the Korean and Chinese animation MAL carries, so laev asks
it. The import also sends up progress the list has never heard about before
clearing marks that were filed in the wrong place, rather than dropping it.

`laev mal import` does the same for anime, from your MyAnimeList list — but on
MyAnimeList's terms, not TMDB's. MAL keeps a season as its own entry ("Lupin III:
Part II" is one anime with 155 episodes), and that is exactly what laev marks:
`mal-1425-e12`, an episode of an anime. Nothing is matched to anything, so
nothing can land on the wrong show. A part-watched anime marks as far as it got;
a one-episode anime — a film, an OVA — is a single mark, because that is all it
is.

Anime hours come from MAL's own episode durations, which it reports per anime and
TMDB frequently doesn't list at all. So the stats page keeps the two apart and
each is counted from its own source:

```
  6910h 09m across 1785 titles · 1390 films · 6544 episodes from 349 shows

  52 series finished · 325 anime finished · 33 watching · 16 caught up · 21 on hold

    4467h 34m  films & tv · 1330 films · 634 episodes from 47 shows
    2442h 35m  anime      · 60 films · 5910 episodes from 302 anime
```

**Watchlist** opens in about a sixth of a second, because the dozen TMDB fields a
row is made of are kept in `cards.json` rather than asked for every time — it was
making seventy-eight requests to draw a page whose answer hadn't changed. Cards
refresh behind the list once they are a day old (a show gains seasons) or a week
old (a film doesn't). It gathers everything you are in the middle of from every
record laev keeps — episode marks, your MyAnimeList list, and its own history — so something
you have progress in here shows up whether or not any list knows about it. A film
you are half an hour into is in the middle of being watched too, and says where
you got to. It lists anime beside shows, in three sections, because there are
three answers to "why isn't this finished":

```
  Dogulwang                      · 11/12 episodes          ← last night
  Your Friends & Neighbors       · 1/2 seasons watched
  Marriagetoxin                  · Ep 7 · at 5:46          ← no list knows this one
  Backrooms                      · at 35:35
  …                                                      38 to finish
  ⌄ caught up ────────────────────────────────
  Severance                      · caught up · 2/2 seasons
  …                                                      16 up to date, waiting
  ⌄ on hold ──────────────────────────────────
  Naruto: Shippuuden             · on hold · 258/500 episodes
  …                                                      21 put down
```

Only the first is a list of things to do tonight, and it is the only one the home
screen counts, and every section is ordered by when you last watched it.
**`ctrl-h` puts a title on hold** and takes it back off — the
status MyAnimeList has had for years and laev was missing, for the large category
of things you got four episodes into and stopped. They used to sit at the top of
this page forever, and marking them watched to clear them would be a lie that
costs you the watch time.

For an anime that status *is* MyAnimeList's, pushed there under the same setting
that scrobbles what you watch; for a show it is laev's own, and it syncs across
your devices with everything else.

**Starting an anime that isn't on your list** needs nothing from you. Finish an
episode and laev adds it as *watching* at that episode — MAL's update is an
upsert — then learns what it is (title, episode count, episode length) and takes
the list's count as its own. That last part matters: a list keeps a count, not a
tick list, so picking something up at episode 7 means seven episodes, and laev
marking one would leave it saying `1/13` beside a list saying `7/13`. It marks
seven, which is also the only honest reading of "I'm on episode 7". The finale
flips the list to *completed* and the anime leaves your Watchlist on its own.
`LAEV_MAL_SCROBBLE=off` if you'd rather laev never wrote to your list. `ctrl-w` likewise marks an anime finished on
MyAnimeList, and unmarking puts it back to *watching* with the count it has, so
the two never disagree about something you just said. Dropped anime stay dropped.

Films and shows are TMDB's; anime is MyAnimeList's; the profile you have been
keeping for years stays the one that counts. Run it as often as you like — it
only ever fills gaps.

Anime laev had previously filed under TMDB ids is cleared the first time you
import, and said so plainly, since the same watching recorded in two numbering
schemes would be counted twice. A position partway through an episode is carried
over rather than dropped.

### Rating what you watch

`laev tmdb login` links your TMDB account — one browser approval, using the key
you already have — and the Now Playing menu then offers `☆ rate this episode on
TMDB`: a list you arrow through, highest first, with a word against each score.

```
10  masterpiece      5  passable
 9  banger           4  not good
 8  really good      3  truly bad
 7  pretty decent    2  garbage
 6  it's alright     1  absolute trash
```

It opens on whatever you gave it last time (7 if you haven't rated it), so
changing your mind is one keypress, and offers `✕ remove my rating` once there
is one to remove.

`☆ rate the whole series on TMDB` sits under it, on every episode rather than
only the finale, and brings your own episode scores with it:

```
how was Your Friends & Neighbors — the whole series? · your episodes average 8.3 (3 rated)
```

The cursor opens on that average, so agreeing with yourself is one keypress and
the only question left is whether the whole was more than its parts or less.

For anime the row goes to MyAnimeList instead — `☆ rate the whole series on
MyAnimeList` — because that is where an anime score belongs and where your list
already is, and `ctrl-o` opens the MAL entry you actually watched rather than
whatever a name search turns up. MAL scores whole anime and nothing smaller, so
**episode** ratings still go to TMDB, the one service that takes them; the cursor
opens on your TMDB episode average either way.

Per **episode**, which is the point: IMDb can't do this. Its official API is
paid, enterprise and read-only, and submitting a rating there means driving a
logged-in imdb.com session through an internal GraphQL endpoint — laev would
have to hold your IMDb password to do it, so it doesn't. `ctrl-o` still opens
the IMDb page for anything, and anime scores can go to MyAnimeList.

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
| `laev mal login` | link MyAnimeList (anime scrobbling and scores) |
| `laev mal import` | mark your MyAnimeList list watched here (anime stats) |
| `laev tmdb login` | link your TMDB account, to rate episodes and films |
| `laev sync` | sync watch state now (`laev sync status` shows config) |
| `laev config` | show config status |
| `laev update` | update and start the new version; says so and stops if there's nothing new |

`laev watch tt13207736` takes an IMDb id as well as a name — unambiguous where
a name isn't (there are two 2026 films called *Runner*), and what you have when
you came from IMDb. Where TMDB's own reverse lookup is wrong, the curated lists
answer instead: that id is one series with four seasons on IMDb and four
separate shows on TMDB, so it opens the curated list of all four.

`laev watch --raw "<text>"` skips TMDB and searches indexers by text.

## Sync across devices (optional)

By default laev is **local-first**: your saved titles, history, resume points and
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
up on your laptop exactly where the phone left off.

Seven collections travel: saved titles, history, positions, holds, track
preferences, and —
so the stats agree wherever you look at them — the measured watch time and the
day-by-day log behind the calendar. That log is one file per device, because it
is append-only: a single shared file could only be merged by letting one
machine's history overwrite another's.

Your **API keys can ride along too**, if you turn it on — Settings → 🔄
Cross-device sync → "carry my API keys". A laev key is then
`laev_<token>.<secret>`: only the token half is ever sent, and the secret half
stays on your machine and encrypts the keys, so the server holds a blob it
can't open. `laev setup` offers **"I already have a laev key"**, which sets a
new machine up with nothing to re-enter. Off by default, and the key is then
worth as much as the debrid account behind it. Your **MyAnimeList login is
never synced** — its token rotates, and two machines sharing one would log
each other out.

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
