# Changelog

Earlier releases are described in full at
<https://github.com/alexdont/laev/releases>.

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
