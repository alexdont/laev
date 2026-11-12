# Changelog

Earlier releases are described in full at
<https://github.com/alexdont/laev/releases>.

## 0.1.55

**A dozen tasks' worth: the library surfaces roki had rewritten, two wrong
numbers in the stats, subtitles that were mojibake, and a browser path that
stopped burning seven cores to watch a 4K film.**

### Playing

**Browser playback copies the video instead of re-encoding it.** Re-encoding
HEVC or AV1 with libx264 takes five to seven cores and a 4K file never keeps
up. Pass `caps:` to `Laev.Remux.start/3` — what the player decodes — and the
`direct` package copies the video as it is into a fragmented MP4 that plays
while it is written, which is also the only way HEVC reaches Safari over HLS.
It decides for itself and answers `:skip` when the codec is not one those caps
decode, so anything else falls through to the segmented path exactly as before.
`Laev.Remux.kind/1` says which kind is on disk, since the two are laid out
differently under the same id, and `direct` is an *optional* dependency: the
terminal plays through mpv, which decodes everything itself.

**One MyAnimeList client, not two.** `Laev.MAL` keeps every function it had and
the protocol half of it is now the `myanimelist` package's — PKCE, the token
refresh, the update spelling MAL's own responses do not use. Tokens stay in the
same `mal.json`, so a login made before this still works.

**One copy of the search rules.** `Laev.Search` holds what was private to the
terminal's search: `parse/1` (title, year, IMDb id), `variants/1` for the
spellings TMDB will not cross-match, `canonical/1`, `rank/3`.

**The hedged race is its own function.** `Laev.Hedge.run/3` races any ranked
list of candidates — another started beside a slow one after `delay_ms`,
`max_parallel` at once, best-ranked answer wins — and says which candidates it
never asked, so a caller can offer them. `resolve_best/2` is written on it.

**Ratings in half steps.** TMDB has always stored them; the picker only offered
whole numbers, so a film better than a seven and not an eight had to be rounded.
MyAnimeList keeps whole numbers, because that is what it stores.

**Esc goes one step out**, not home, from every screen — the screens are a
stack now (`Laev.Nav`) — and the player's menu can get back to the list a title
was picked from: the search results, Saved, the Watchlist.

**A remux worker whose ffmpeg died gives its id back** instead of holding it
for two hours while serving a playlist that will never grow, and a conversion
with no playable playlist after two minutes is stopped as stuck rather than
waited out as idle.

### Reading a subtitle file

**Subtitles in Japanese, Russian and Chinese are readable.**

A subtitle file carries no declaration of its encoding, and laev read anything
that was not valid UTF-8 as Latin-1 — right for the French and other Western
European releases it was written for, and mojibake for every Shift-JIS anime
release, Windows-1251 Russian fansub and GBK Chinese one. It did not fail
either: it produced a wall of `ã‚ã‚Š` that looks like a laev bug.

`Laev.Encoding` works the encoding out from the bytes, in order of how much the
evidence is worth:

1. A byte-order mark — UTF-8, UTF-16 either way round.
2. UTF-16 with no mark, from the NULs every second byte that ASCII in UTF-16 is
   full of (which is what Windows subtitle tools write).
3. Valid UTF-8, which is nearly everything.
4. A multi-byte code page whose structure the high bytes actually fit —
   Shift-JIS, EUC-JP, GBK. One byte out of place rules one out.
5. A single-byte code page, from how the high bytes sit: Cyrillic words are
   runs of them, a French accent sits alone between ASCII.

Where more than one fits — Shift-JIS allows a trail byte almost anywhere, so a
file of `0xA1..0xFE` pairs parses as all three — the rows decide. Shift-JIS
keeps kana and most kanji in `0x81..0x9F`, which EUC-JP does not use for leads
and GBK rarely reaches; EUC-JP and GBK are separated by the kana rows `0xA4`
and `0xA5`, which Chinese has no use for.

Decoding UTF-8, UTF-16 and Latin-1 is OTP's. The code pages need mapping tables
OTP hasn't got, so laev shells out to `iconv` — the way it shells out to mpv and
ffmpeg, with no NIF to compile and nothing to configure. Without it (or if it
refuses the bytes) the result is the Latin-1 reading, exactly as before, and
`laev doctor` now lists `iconv` among the optional binaries so a missing one is
visible rather than silent.

### Numbers that were wrong

**A runtime laev could not look up is no longer remembered as "no runtime".**

`runtimes.json` stored a failed lookup and a real answer the same way, as
`"unknown"`, and kept it for good. So one run without a TMDB key — or on a
train, or during a TMDB outage — taught the cache that every film it touched
was zero seconds long, and every later run agreed: an account's 6,940 hours
read as 2,500.

The three cases are now told apart:

* **An answer.** TMDB replied and lists no runtime, or has nothing at all under
  that id (a 404). Remembered, but **dated**, so a title whose runtime is
  filled in later is asked about again after a month rather than counted as
  nothing forever.
* **A failure to ask.** `:no_tmdb_key`, a 401 from a bad key, a 429, a 500, a
  timeout, a refused connection, or MyAnimeList not answering. **Never written
  down** — a failure of this machine's is not a fact about the film. It is used
  for the run and forgotten, so the next run asks again.
* **A number.** Unchanged.

`Laev.Stats.all_time/0` now also returns `unmeasurable:` (how many titles this
run could not ask about) and `tmdb:` (whether a key is configured), and `laev
stats` says so out loud rather than presenting a short total as the answer —
the totals are short by whatever those titles run to, and nothing was written
down as zero.

**Caches this bug already spoiled heal themselves.** A bare `"unknown"` is what
older laevs wrote for failures and answers alike, so it is no longer believed:
it is dropped on load and looked up again. A dated one keeps the date it was
learned on — writing the cache does not refresh it, or the month would never
come round.

For `roki`: `heal_runtimes/0` and refusing to build without a TMDB key are no
longer needed.

## 0.1.54

**Why the tick log had days of nothing in it, and why the day log had too much.**

A second report from the same library user: the tick log was missing five
consecutive days that the day log beside it had, and a 30-minute film left no
trace at all. Four separate things, and the one the report was surest about was
not the one causing the hole.

### Every mpv play was missing from the tick log

The two logs are written from different places, and only one of them survives
laev closing. The mpv script writes the position, the played file and the day
log *itself* — deliberately, so that a film survives laev exiting, mpv being
killed or the machine losing power. The tick log was written only by laev's own
side, from `Position.record/2`, which an mpv play never reaches: laev launches
the player and goes.

So the days with plays and no ticks are mpv days, and the plays with ticks were
the browser and VLC paths all along. The script now writes ticks too, a minute
at a time (a tick is a stretch of watching, not a five-second sample), flushed
when playback ends — `laev-ticks` and `laev-key` passed beside the day log. The
Lua tests run the real script under an interpreter and check that the ticks add
up to what the day log says.

### Resuming a film logged its earlier sessions again, onto today

`load_played` assigned `logged` before the `local logged` was declared, which
in Lua writes a *global* of that name while the functions that read it see the
local. It therefore stayed 0 for every resume, with `watched` already loaded
from the played file, so the first save wrote **the whole of a film's earlier
sessions to today**. Forty minutes watched last night, resumed tonight, counted
again tonight. Both counters are now declared above everything that assigns
them and reset from what was loaded.

### Extending a line in an unterminated file glued two of them

`open_tail/1` computed the last line's offset as `size - byte_size(last) - 1`,
where the `- 1` is the newline after it. That is only right for a file that
ends in one. For a file that doesn't — what sync wrote back before 0.1.53, or
what a process killed mid-write leaves — it pointed one byte early, at the
newline ending the *previous* line, and the truncate-and-rewrite then merged
the two:

    1793960473 tv-289517-s1e8 3511793960669 movie-1657630 4

This is where laev made those lines itself, rather than inheriting them from
sync. The start of the last line is now found rather than computed, and the
rewrite leaves the file terminated. The mpv script also writes the newline a
damaged log is missing before appending to it.

### And three smaller things from the same report

* **Two writers no longer race.** Extending means read-the-tail, truncate,
  write; two callers doing that at once (two progress posts, a poller and a
  page) could have the second overwrite the first. It is serialized per file,
  and a lock nobody can take falls through to appending, which is always safe.
* **A lost tick says so.** The write ended in `rescue _ -> :ok`, and a silence
  is indistinguishable from not having watched anything. Failures are logged.
* **A pull cannot shorten this device's own log.** Only this machine appends to
  `ticks/<device>.log`, so a pulled copy can be behind it but never ahead, and
  writing it back would discard whatever has been watched since the last push.
  It is applied when there is nothing here (a restored machine wants its
  history) or when it genuinely extends what is here, and a tombstone for it
  from a device that hasn't got the file no longer deletes it.

Ticks that were never written cannot be recovered; the day log keeps those
days, as it always did.

## 0.1.53

**Sync was breaking the logs it carried, and the day totals were fiction.**

Reported against 0.1.52 by somebody running laev as a library, and worse than
the report had found.

### The cause

`read_dir/1` trims every file it reads into the bundle, so an append-only log
reached the wire without its final newline, and a pull wrote it back that way.
Everything that writes those files only appends, so the next line fused onto
the last one:

    1793450449 movie-1283515 11793460753 tv-110316-s2e1 1
    2026-10-31 12026-11-01 1

A pulled log is now written with exactly one trailing newline, while
single-record files (positions, tracks, played, dated, holds) are still written
byte for byte. Trimming on the way *out* stays, so two devices still agree on a
log's bytes and no log looks changed once because of this.

### What it cost, measured on a real account

In `ticks/` the fused line parses as neither entry, so both were dropped: a log
of 18 lines gave 358 of the 496 seconds it holds.

In `watched/` it was worse, because `Integer.parse/1` stops at the first
non-digit and took `12026-11-01` for **12,026 seconds**. 64 fused lines claimed
**4,470 hours** of watching that never happened, and the day totals read
243,288 hours against an actual 150.

### Logs already damaged read correctly now

Both readers split a fused line where the seam is exact — a tick's time is a
ten-digit epoch, a day's is a full `YYYY-MM-DD` — and skip anything that isn't
unambiguous, as they always did with a line laev didn't write. Nothing has to
be repaired by hand, and the recovered seconds are back in stats and sessions.

Two further things that only turned up in the real data:

* **A day's line cannot exceed a day.** Compaction had folded fused lines with
  the lenient parser and written the sums back, so `2026-09-30 194322026` is
  all that is left of that day — the original seconds are unrecoverable. A line
  claiming more than 86,400 seconds is proof of damage, and is skipped rather
  than shown as 184,756 hours.
* **Compaction keeps a backup.** Folding replaces a log with a summary of
  itself, which is how those originals were lost. It now copies the file to
  `<log>.bak` first.

## 0.1.52

**AnimeTosho is gone, and laev stops asking for it.**

Every anime search spent part of itself on a host that no longer exists. Anime
Tosho shut itself down — announced on 2026-02-05 ("will begin shutting down
permanently in May 2026"), new torrents stopped on 2026-05-09 — and the one
host it served every feed and API call from, `feed.animetosho.org`, left DNS
around 2026-10-26. NXDOMAIN from the zone's own nameservers, so it is gone
rather than blocked, while the archive site still runs and still documents that
host on its own about page. `laev doctor` was the only place it showed.

There is nothing to repoint at. The apex's feed paths answer 404, and the
`animetosho.net` and `animetosho.xyz` domains that turn up as the official
migration are referenced nowhere on the real site and sit on unrelated
infrastructure. A lookalike of a dead tracker is not somewhere to send
somebody's search queries, so laev doesn't, and a test fails if any module
names one.

**What it cost: nothing that wasn't already covered.** AnimeTosho was a third
text indexer that mostly duplicated Nyaa, and the only source laev could ask by
**AniDB id** — a show by number instead of by title. That precision now comes
from Torrentio by Kitsu id, which ran beside it all along. Measured on the live
path, Frieren episode 3:

    torrentio kitsu:46474:3   107 sources   208ms
    whole episode search       40 sources  1535ms

with the merged page coming from Nyaa and five trackers Torrentio fronts, and
episode-exact files ranked first. So the AniDB id is no longer looked up for
searching (`Laev.AnimeMap.anidb/1` and `Laev.Kitsu.anidb_id/1` stay — the
mapping file carries the id for free), and the `:anime` text backend is Nyaa.

## 0.1.51

**Two things that came with 0.1.50, one of which stopped it launching on macOS.**

### The macOS binary crashed at boot

```
dlopen(.../laev_erts-17.1_0.1.50/lib/asn1-5.5.2/priv/lib/asn1rt_nif.so):
  slice is not valid mach-o file
```

It had a Linux library inside it. 0.1.50 pinned the bundled runtime to OTP
29.1 because the CDN burrito fetches from has no build of 29.1.1, which is what
this machine compiles with — and that one patch release apart is what did it.
Burrito assembles the release from the local Erlang and then replaces the NIF
libraries with the target platform's, matching them by path: OTP 29.1.1 ships
`asn1-5.5.2`, 29.1 ships `asn1-5.5.1`, so the macOS library landed in a
directory the release does not have and the Linux one stayed where the release
does look. Nothing failed at build time. It failed at boot, on the user's
machine, and took the VM down with it.

So the bundled version is no longer a number kept in `mix.exs` to be updated.
It is read from whatever Erlang is building, and a release step asks the CDN
whether it has that version *before* wrapping anything — if it doesn't, the
build stops and names the Erlang to build with instead. The binaries are built
with OTP 29.0.6, matched exactly, as 0.1.49's were.

### `Logger - error: {removed_failing_filter,logger_translator}` on the screen

`Laev.Log` removes every log handler, because they all write to the terminal
laev is drawing in. A filter runs *before* the handlers, though, and when one
crashes the logger reports it with `erlang:display/1` — straight down file
descriptor 2, past every handler and past anything laev could install.

The filter that crashes is Elixir's `logger_translator`, and it crashes for the
reason `Laev.Log` exists: it reaches for the pretty-printing machinery, out of
the unpacked payload directory the standalone binary runs from, after an update
has replaced that directory. Nothing in laev needs it — the file handler
formats reports itself, with nothing lazily loaded — so the primary filters are
now removed along with the handlers, and every event reaches the handler, which
is what they were in the way of anyway.

## 0.1.50

**Syncing while you watch, and a much smaller footprint on the debrid account.**

### Watching four episodes used to sync none of them until you quit

Marks, resume points and watched flags piled up locally and left in one burst
on exit, so a second machine read stale progress for the whole session. Three
reasons, all fixed:

* `continue_entry` and `reopen` — the Continue row and re-opening what is
  already playing — launched a player and went straight to the menu. No MAL
  scrobble, no resume push, and no watcher to push the finished episode. Only
  the search path was wired up. All three now go through one `track_playback/1`,
  and a test reads `cli.ex`'s own syntax tree to assert that every function
  which starts a player calls it.
* `live_push/0` was gated on `LAEV_SYNC_LIVE`, which is off by default, while
  setup turns `LAEV_SYNC_AUTO` on. Eighteen call sites — watched marks, pins,
  holds, ratings, the Shelf, the Completed page — silently did nothing for
  everyone running the default configuration. Either switch now pushes.
* Which also closes the third gap: a mark made after the end-of-episode watcher
  had already fired no longer waits for exit.

Resuming a show also scrobbles to MyAnimeList again, which was broken on the
same path and just as quietly.

### Probing left a torrent in your account for every source it ever checked

Measured on a real account: a hundred entries inside twelve hours, five to
thirteen per title watched, four stuck in `magnet_conversion`, and three still
downloading files nobody would ever watch — which costs the provider real
bandwidth, not an API call.

Two causes. Real-Debrid does *not* dedupe by hash, whatever the old comment in
`rd.ex` claimed: adding a magnet the account already has answers with a new id,
verified against the live API. And `resolve_best/2` kills the losers of a hedged
race where they stand, so the `delete_torrent` at the end of a failed resolve
never ran for them.

So a probe now claims the torrent it creates and `Laev.RD.Ledger` watches the
claimant: a claim released is kept — it resolved, and switching source on the
picker's page must not need a second resolve — while a claimant that dies still
holding one has abandoned it, and it is deleted. Claims are written to disk as
well, because a laev that is killed outright takes its monitors with it.

`Laev.RD.Sweep` is the pass that finishes the job on the next launch (quietly,
at most once every six hours) or on demand with the new `laev clean`. It is
deliberately narrow about deleting from somebody's account: `error`,
`magnet_conversion` older than ten minutes, and `downloading` torrents laev's
own ledger recorded abandoning. Never anything `downloaded`, and never anything
whose infohash is in your resume history, whatever its status — from the
provider's side a download you started looks exactly like one laev abandoned.
`LAEV_RD_SWEEP=off` turns it off.

### Watching the same thing twice costs nothing

A resolve is five requests and cannot be fewer — add the magnet, read the file
list, select the file, wait for the link, unrestrict it — and the endpoint that
once answered "is this hash cached?" for a whole page at once now answers
`403 disabled_endpoint`. So the only calls left to save are the ones made
twice, and they are made twice constantly: resuming, pressing play after
stopping, continuing a show the next evening.

`Laev.RD.Cache` remembers what a source resolved to, per episode, for a day.
Measured on the real path:

    first  (cold)   649ms   5 Real-Debrid calls
    second (warm)   416ms   0 Real-Debrid calls

Same file both times. A stored link is checked before it is trusted, because
the player is detached and an expired link would fail where laev can no longer
retry — one HEAD against the download host, which counts against no rate
limit. Read carefully, too: the host serves the file for any filename as long
as the id is good, so what separates a live link from a dead one is the length
it reports, not the status code. A miss resolves from scratch exactly as
before. `LAEV_RD_LINK_CACHE=off` turns it off.

### Waiting on the provider asks fewer times

Polling backs off (500ms, doubling, capped at 3s) instead of asking once a
second. The window is exactly what it was, so nothing is given up on sooner
than it used to be, and waiting out a source that never comes up costs seven
requests instead of ten. An honest trade rather than a free win: fewer looks
means a coarser answer later in the window, and the five-second window the
probes use costs what it always did.

### Building

The runtime the standalone binaries bundle is pinned to the newest OTP the BEAM
Machine CDN actually carries (29.1), rather than to whatever the build machine
was last updated to: building on 29.1.1 fetched a 404 for both targets.

## 0.1.49

**Pressing play checks one source, not eight.**

Auto-pick probed a page of eight releases and then played the best of them.
But the pick is `hd(usable)` — the highest-ranked source that resolved, within
the resolution ceiling, not a cam rip — so probing in rank order and stopping
at the first answer chooses the same release. The other seven probes could
never change what played.

What they cost, measured rather than guessed. Each resolve is six Real-Debrid
requests, so a page was around forty-eight; and because the page was only as
quick as its slowest member, it was *slower* as well as dearer. Two trending
films, the same sources, both paths:

    Primetime                 30143ms  55 requests  →   470ms   5 requests
    Apocalypse Z: New World   16509ms  55 requests  →  1729ms   3 requests

Same pick in both cases. Across nine titles, eight resolved on the first
attempt, between 516ms and 2444ms.

It is not simply sequential, because failures stack: one title's first two
sources failed in 1.5s and 1.3s and its third hung for 11.8s, which served one
at a time is fifteen seconds of nothing. So if the best source has not answered
within 2.5 seconds a second is started *beside* it, up to three at once, and
the best-ranked of whatever answers wins. That case went from 31868ms and 30
requests to 13794ms and 18.

Where this can pick differently: only when the leader is slow enough to be
hedged and a lower-ranked release answers first. That is the trade on purpose —
a good source now against a marginally better one later — and it cannot happen
at all on a play where the first source answers in time, which is most of them.

Asking for another source still gets the whole list, probed at that point
rather than on the chance that somebody might ask. The quality-diverse page of
eight is what the picker is still made of.

`Laev.Providers.resolve_best/2` takes `hedge_after:` (default 2500ms),
`max_in_flight:` (3) and `resolver:` for testing.

## 0.1.48

**`laev tmdb import-imdb <ratings.csv>`** — a watch history with its dates.

TMDB's rated endpoints carry no rating date, so `import_from_tmdb/1` can say
only that something was watched. An account with a decade of IMDb ratings
copied into TMDB therefore imported five hundred titles with no history at all.
The dates live in IMDb's own export, and `Laev.Ratings.import_imdb_csv/2` reads
it: resolve each `Const` through `Laev.Tmdb.find_imdb/1`, mark the title
watched, and date it by the day it was rated. Episode rows are left to the shows
they belong to and counted as skipped rather than quietly dropped.

A claimed date is kept deliberately apart from one laev measured. The other two
sources prove themselves — a tick-log session was observed, a long measurement
was measured — and this is somebody else's record, so it is written as exactly
that, under `dated/<key>`, and never as a forged measurement or a tick claiming
time nobody counted. Stats still treats such a title as time *assumed*, which
is what it is, and now knows which day to put it on. `Laev.Position`:
`set_watched_on/2`, `watched_on/1`, `claimed_dates/0`. Synced as its own
collection.

Read in that order wherever a date is wanted — a session, then laev's own play
history, then a claimed date — on the shelf, on the Completed page and in the
stats windows, which previously left an imported catalogue in "all time" and in
none of the others.

**`Laev.Csv`**: enough RFC 4180 to read an export — quoted fields with commas,
doubled quotes, a byte-order mark. Not a dependency, because a terminal
application should not grow one for twenty lines.

Worth knowing for anyone who imported before this: an undated mark has read as
undated rather than as today since 0.1.47, so the symptom is already gone; this
is what puts the real dates back.

## 0.1.47

**A resume stamp is no longer read as a watch date.** `Laev.Shelf`'s
`last_watched_at` read a resume entry's `updated_at`, which is stamped the
moment a source resolves, before a frame plays — so pressing play and closing
the player five seconds later told every screen you had watched that title
today. Witch Hat Atelier, watched on MyAnimeList years before laev existed,
had six measured seconds from a browser test, and its eight imported marks —
three hours of them — sat in the last seven days.

The question is answered by what was measured, in order of how much each source
knows: a session in the tick log, which exists precisely to say when; failing
that, a measurement of at least two minutes, which vouches for the stamp for
anything recorded before the log existed; otherwise undated, because the stamp
knows only that a player was opened. Anime is dated by MyAnimeList's own
timestamp, which is what it should always have been.

`updated_at` keeps its meaning and keeps being stamped at resolution — it is
what orders "continue watching", and that is the reason one field could not
serve both.

On the account this was found on, five titles lost a date and all five had
earned it: 0, 0, 0, 1 and 7 seconds of measurement between them.

**Elixir 1.19 is enough.** The requirement said `~> 1.20` because that was the
version to hand, not because anything needed it — the whole suite passes on
1.19.6. Relaxed, so a 1.19 toolchain stops warning on every compile.

## 0.1.46

**A tick log, and the sessions it folds into.** `ticks/<device>.log`, synced as
its own collection, one line per sample:

    1793000120 movie-27324 5

Unix seconds, the key the position files already use, and the seconds that
sample measured. `Laev.Stints.ticks/0` reads every device's; `sessions/1` folds
them into bounded periods of activity, so "what was I watching on Tuesday
evening" has an answer. Session ends are inferred from the silence rather than
reported, because players are killed and laptops close and nothing can be
relied on to say stop. Written from `Laev.Position.record/2`, which every
player funnels through, so the mpv script, the VLC poller and a browser all
land in the same record.

The log folds as it is written: a tick that carries straight on from the line
at the end of the file replaces it rather than appending. A two-hour film is
one line instead of fourteen hundred — which matters because a directory syncs
as one record holding the whole file, and a year of unfolded ticks would pass
the sync document's five megabyte ceiling on its own. Only where the watching
is continuous, though: merging a tick that came after a pause would move the
session's start forward by the length of the pause, since a start is read back
as `at - seconds`. A pause writes a second line.

**A finished mark is no longer undercut by a sliver of measurement.**
`Laev.Stats` preferred the `played/` figure whenever one existed, which is
right for a play the mpv script followed and wrong for the ordinary browser
case: a position of `done` beside four minutes of measurement. Avengers:
Endgame read as 254 seconds. Where the mark says finished and the measurement
is under half the runtime, the runtime is counted and the difference is
*assumed* rather than measured — the bucket a mark made by hand already lands
in, because that is what it is. A title with no known runtime is left alone and
a real measurement keeps its own figure. On the account this was found on: 34
entries and **28h 15m** recovered.

## 0.1.45

**Fifty-nine anime franchises.** TMDB files a franchise's parts as unrelated
things — Bleach is one show and its four films are a collection; Naruto,
Shippuden and Boruto are three shows; Fate is nine — so opening any of them
showed that part alone. Ranked by MyAnimeList membership with each franchise's
entries summed, and generated by `tools/build_anime_franchises.py`, which holds
queries rather than ids: each is resolved against TMDB, checked for type and
year, and anything that does not resolve is reported instead of guessed.
One Piece, Naruto, Dragon Ball, Detective Conan, Pokémon, Yu-Gi-Oh! and Gundam
are tiered into Series and Movies.

- `Laev.Franchises.all_for_title/1` names each list once. A series is listed a
  season at a time, so a seven-season show used to answer "Star Wars" seven
  times — invisible through `for_title/1`, wrong for anything listing the lists
  a title is in.

**What roki was working around**

- **Remux start.** The worker ran four ffprobe processes, each re-opening the
  same remote URL: 5.7 seconds before the first segment against 1.4 for one
  call, measured. `Laev.Remux.Worker.probe_streams/1` reads every stream's
  kind, codec and language in one go.
- **`Laev.Scope.with_overrides/2`** runs work with some settings replaced
  without touching what anyone saved — one film in French for somebody learning
  French. Carried by `async/1`, `async_stream/3` and `spawn/1`, which is the
  point: the work that finds sources happens in other processes.
- **`Laev.Sources.audio_in?/2`** and `rank/2` with `strict_audio:` and
  `max_resolution:`. The language has to be in the *audio* — a French subtitle
  on a Japanese dub is not French speech — and the limit applies before releases
  are checked rather than after. A release whose tracks were never read answers
  `nil` rather than `false`, so filtering cannot discard everything unexamined.
- **`Laev.Anime.Parts`** learns the episode lengths it is missing, from
  MyAnimeList and then Kitsu, instead of reading only the current user's list.
  Bleach season 2 is four cours of thirteen; with the third missing from an
  account, episode 30 placed itself in the fourth. Also `Parts.ready?/2`.
- **`Laev.Tmdb.recommendations/3`** and `similar/3`, in the same card shape as
  `trending/2` — recommendations first, topped up from similars, posterless
  results and the title itself dropped.
- **`Laev.Ratings.score_words/0`** and `score_word/1`, so the ten words exist
  once. Takes integers and floats alike; the float-only version crashed on a
  stored 7.
- **`Laev.Sources.search/2` takes `backend_timeout:`** — an anime search waits
  about sixteen seconds on Nyaa while four other sites answered in two. With a
  deadline it returns what arrived and says how many are still thinking;
  without one, nothing changes.
- **`Laev.Config.normalise_lang/1`**: "fr", "FR", "fre", "fra", "French" and
  "français" are one code now, so a setting typed in a terminal means what a
  dropdown means. `lang/0` and `subs_lang/0` normalise.
- **`Laev.AnimeMap.consistent?/2`** says when a show's MAL entries point
  somewhere else, and `Parts` warns once per show rather than answering
  quietly. The Bleach case that prompted it turned out to be the list being
  right.

## 0.1.44

- **A Completed page**, beside Search: everything you have finished, newest
  first, a hundred rows at a time. Enter watches something again, ctrl-o opens
  its page. The Watchlist says what you are in the middle of and this says what
  you are done with — films, series and anime together, including the ones
  imported from MyAnimeList and the ones ticked off by hand, which the play
  history alone does not know about.
- The order is when, not what, because the question it answers is "what was I
  watching around then". A sync rewrites every mark file, so their timestamps
  all read as today; the dates come from laev's own history, and from
  MyAnimeList for anime, which survives a reinstall. What has no real date sits
  after what does rather than leading, and says nothing rather than today.
- Names come from the history as well as the name cache, which had two thousand
  titles in it and not Meet the Parents — whose name was sitting in the history
  all along.

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
