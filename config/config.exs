import Config

# laev owns the whole terminal: fzf draws a frame, mpv's position tracker
# writes under it, and `Laev.Quiet` exists because even one stray line from a
# background task scrolls the screen out from under the cursor.
#
# The logger's default handler writes to exactly that terminal, and on a long
# session it eventually has something to say — a TLS alert when the laptop
# sleeps and its connections die, a DNS failure on a network change. One such
# report took a Mac down: the handler went to format it, needed `io_lib_pretty`
# and `Inspect.Opts`, and neither is resident at boot. They load lazily, out of
# the unpacked payload directory the standalone binary runs from — which was
# long gone by then — so the format crashed, the crash was itself logged, and
# that log crashed the same way, forever, scrolling the whole screen away.
#
# So no handler is installed at all. `Laev.Log` adds a file one at boot, out of
# the way, and preloads what formatting needs so the same vanishing payload
# can't take that down too.
config :logger, :default_handler, false
