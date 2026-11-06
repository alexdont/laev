defmodule Laev.AnimeToshoGoneTest do
  use ExUnit.Case, async: true

  # AnimeTosho was an anime indexer and, more usefully, the only one laev could
  # ask by **AniDB id** — a show by number rather than by title. It shut itself
  # down: announced 2026-02-05 ("will begin shutting down permanently in May
  # 2026"), stopped taking new torrents 2026-05-09, and the one host it served
  # every feed and API call from, `feed.animetosho.org`, left DNS around
  # 2026-10-26. NXDOMAIN from the zone's own nameservers, so it is gone rather
  # than blocked, while the archive site still runs and still documents it.
  #
  # This test exists because the obvious repair is wrong. Searching for the new
  # endpoint turns up `animetosho.net` and `animetosho.xyz`, offered as the
  # official migration by a handful of unfamiliar repositories. The real site
  # references neither, anywhere, and both sit on unrelated infrastructure. A
  # lookalike of a dead tracker is where somebody's search queries should not
  # go, however plausible the hostname.
  #
  # So: no laev module may name any of these hosts, and the id-keyed path is
  # Torrentio by Kitsu id, which ran beside AnimeTosho all along.

  @hosts ["feed.animetosho.org", "animetosho.net", "animetosho.xyz"]

  test "no module calls a host that is gone, or a lookalike of one" do
    for path <- Path.wildcard("lib/**/*.ex"),
        source = File.read!(path),
        host <- @hosts,
        String.contains?(source, "https://" <> host) or
          String.contains?(source, "http://" <> host) do
      flunk("""
      #{Path.relative_to_cwd(path)} requests #{host}.

      AnimeTosho shut down; the .net and .xyz domains are not it. Anime search
      is Nyaa for text and Torrentio by Kitsu id for the exact show.
      """)
    end
  end

  test "and the id-keyed anime path is still there" do
    assert Code.ensure_loaded?(Laev.Sources)
    assert function_exported?(Laev.Sources, :torrentio_anime, 2)
    assert Laev.Sources.torrentio_anime(nil, 3) == {:ok, []}, "no id, no request"
  end
end
