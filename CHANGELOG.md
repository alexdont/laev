# Changelog

Earlier releases are described in full at
<https://github.com/alexdont/laev/releases>.

## 0.1.43

- **ctrl-w marks a whole anime entry.** Anime has no season picker — a TMDB
  season is not what MyAnimeList counts, so the "which season/entry?" list is
  where a season is chosen, and it took every key except the one that marks a
  season off. Finishing Cowboy Bebop's 26 episodes, watched years ago
  elsewhere, meant opening it and ticking twenty-six rows. One press now marks
  the entry through, a second clears it, and the progress goes up to
  MyAnimeList so the site agrees with the terminal.
- **Ticking episodes tells MyAnimeList.** It didn't: a series ticked through in
  the terminal sat on the site saying "watching, 3 of 26". The marks now go up
  with the episode total beside them, so the last one completes the entry
  rather than leaving it watching forever — and where laev doesn't know the
  total it asks, since without one the last episode looks like any other.
- **ctrl-o opens the entry under the cursor.** It only worked on the row
  outside the entry list, which resolves to a single entry for the whole show,
  so from a list naming season one and season two there was no way to open
  season two. Cyberpunk: Edgerunners and Edgerunners 2 are different pages and
  now open as such.
- **A key that exists on a Mac.** "Mark everything through here" was alt-w, and
  macOS terminals send Option as a composed character rather than as Meta
  unless somebody has changed a setting — so it never reached fzf and the hint
  named a key that did nothing. ctrl-g does the same thing; both are bound
  everywhere, and the hint names whichever works on the platform it is read on.

## 0.1.42

Fixes reported by a second application using laev as a library, so the
terminal gets them too.

**Picking the right episode out of a pack.** `Laev.FilePick.choose/4` fell back
to the largest file when nothing in a pack named the episode, and called it
playable: a pack named "(13-25)" answered a request for episode 2 with episode
13. It returns `{:error, :no_file_for_episode}` now; a caller that wants the old
behaviour asks for `fallback: :largest`. A film, where the largest file is the
right answer, is unchanged.

- `13v2` is the second cut of episode 13, not episode 2. Version markers are
  stripped before matching.
- New `Laev.Episodes`: a release named with a range that starts above one
  numbers its files across the whole TMDB season, so it is asked for the TMDB
  number rather than the one inside its own cour. `Laev.Providers.probe_sources/2`
  takes `ctx:` and groups releases by the number each uses.
- What a provider hands back is checked against what was asked for: a file
  saying `S02E01` is not season 1 episode 2, however well it plays.
- Probing runs four at a time rather than two.

**Anime that TMDB has merged.** New `Laev.Anime.Parts`: where two MyAnimeList
cours share one TMDB season — twelve plus thirteen as a season of 25 — the
entries are laid end to end, so episode 13 of the season is episode 1 of the
second entry. Without it half a season was searched for, and marked, under the
wrong anime. `Laev.Anime.page_url/4` and `entry_for/3` make the MyAnimeList
entry of a season public, for per-season links and per-season ratings.

**ffmpeg no longer takes the host down.** A 4K H.265 release was re-encoded at
source resolution with no speed preset: it never reached real time and took
every core trying, and four of them put a host near a load average of 150.

- A fast preset per encoder, output capped at 1080p, 8-bit 4:2:0. Measured on a
  4K HEVC source: 76s of wall time for 60s of video before, 45s after.
- `Laev.Playback.ready/3` stops the conversion when the wait times out, instead
  of leaving it running for its full two hours.
- `Laev.Remux.Reaper` stops conversions nobody has asked for in ten minutes;
  whatever serves the segments calls `Laev.Remux.touch/1`.
- `Laev.Playback.heavy?/1` and `allowed?/2` let a caller refuse a re-encode
  above a height, or when enough are already running.

**Subtitles.**

- `Laev.SubtitleFetch.candidates/3` lists what is on offer rather than only
  laev's pick, and `download/1` keeps each file for good — a free OpenSubtitles
  account has a small daily quota.
- `Laev.OpenSubtitles.verify_login/2` says what the service meant: its 400 is
  "that is an email address, not a username", which nothing in the raw reply
  conveys. `state/0` distinguishes no key, key-only (search works, downloads
  need the login) and both.
- `OPENSUBTITLES_USERNAME` and `OPENSUBTITLES_PASSWORD` are settings now,
  validated against the service. They were in the config all along with no way
  to manage them.
- `Laev.Jimaku.candidates/4` offers the plausible Japanese files with the
  release's own group first, rather than the first file found — which is often a
  streaming cut running half a minute off a rip.
- `Laev.Subtitles.to_vtt/2` reads Latin-1 and UTF-16 files instead of mangling
  them, which is most French releases.

**Also**

- New `Laev.Setup.first_run/1`: check every key against its service, make a
  laev key, connect, save, sync — and leave nothing behind on failure. The
  terminal's wizard and a web form now do the same thing.
- New `Laev.SyncServer`: the merge rules a host needs to serve the sync API,
  so the two copies of them can become one. Storage and routing stay the
  host's; see the module docs for why the HTTP layer is not here.
- The cross-id anime map was cached in one place for every user, so a scope
  without one answered out of another's.

## 0.1.41

- Hosted sync moved to `roki.ee/api/laev`. The old address
  (`sasha.don.ee/laev`) still forwards and keeps working, so nothing needs
  doing; a config file holding exactly that old address is brought forward
  once, while a server you run yourself is left alone.
- The CLI no longer keeps its own copy of the hosted address, so the two
  cannot drift apart again.

## 0.1.40

- First release usable as a library: `Laev.Scope` (a user is a directory plus
  their keys), `Laev.Shelf` (the Watchlist as rows and counts),
  `Laev.Playback` (play in a page, in mpv, or in VLC), `Laev.Settings`, and
  `Laev.Sync.connect/2`.
- A user who had never connected a laev key read the machine owner's.
  Identity is no longer inherited; a key a server deliberately shares still is.
- `Sync.check/0` reported an account holding thousands as empty.
- A missing TMDB key raised instead of returning an error.

## 0.1.39

- Published to Hex as `laev`. The application was renamed from `:laev_app`,
  and Burrito became optional so a library consumer doesn't pull a
  binary-packaging tool.
