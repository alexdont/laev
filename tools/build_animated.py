#!/usr/bin/env python3
"""Build the curated "Animation" list in priv/franchises.json from TMDB.

Every animated feature the big animation studios have released, in release
order, so the list answers "have I seen all of these" without anyone typing
two hundred ids. Run it again when a new film comes out:

    tools/build_animated.py $TMDB_API_KEY > /tmp/animation.json

Three things decide what is a feature, and all three are needed:

  the studio      TMDB files a studio's output under several company ids, one
                  per era — Disney's canon is split across four, and asking
                  only the current one finds eighteen films instead of
                  sixty-seven.
  the runtime     from the *details* endpoint, not discover's filter, which
                  passes 21-minute TV specials ("Madly Madagascar") straight
                  through. A feature is sixty minutes.
  released        a film that isn't out yet can only ever be unwatched, and a
                  list of things to tick wants none of those. The watchlist and
                  the calendar are where the unreleased belong.

A film made by two of these studios (Chicken Run, Aardman *and* DreamWorks)
carries both tiers and appears once.
"""
import json, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date

KEY = sys.argv[1]
API = "https://api.themoviedb.org/3"

# tier key, label, blurb, TMDB company ids ("|" = any of them). The ids were
# resolved with /search/company, and the multiples are eras of one studio, not
# guesses: Walt Disney Productions (1937-80s), Feature Animation (1986-2006),
# Animation Studios (2007-).
STUDIOS = [
    ("disney", "Disney", "the Walt Disney Animation canon, Snow White on", "3166|171656|6125|158526"),
    ("pixar", "Pixar", "every Pixar feature", "3"),
    ("dreamworks", "DreamWorks", "Shrek, Kung Fu Panda, How to Train Your Dragon", "521"),
    ("illumination", "Illumination", "Despicable Me, Minions, Mario", "6704"),
    ("sony", "Sony Animation", "Spider-Verse, Hotel Transylvania, Cloudy", "2251"),
    ("stopmotion", "Stop-motion", "LAIKA and Aardman — Coraline, Wallace & Gromit", "11537|297"),
    ("other", "Everyone else", "Blue Sky, Warner Animation and the rest", "9383|25120"),
]

MIN_RUNTIME = 60
MIN_VOTES = 50


def get(path, **params):
    params["api_key"] = KEY
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def discover(companies, today):
    """Every animated film a studio has released, paged out."""
    films, page = {}, 1
    while True:
        body = get(
            "/discover/movie",
            with_companies=companies,
            with_genres=16,
            include_adult="false",
            sort_by="release_date.asc",
            **{"release_date.lte": today, "vote_count.gte": MIN_VOTES},
            page=page,
        )
        for f in body.get("results", []):
            films[f["id"]] = f
        if page >= body.get("total_pages", 1) or page >= 20:
            return films
        page += 1


def runtime_of(movie_id):
    try:
        return get(f"/movie/{movie_id}").get("runtime") or 0
    except Exception:
        return 0


def main():
    today = date.today().isoformat()
    tiers_by_id, films_by_id = {}, {}

    for key, label, _blurb, companies in STUDIOS:
        found = discover(companies, today)
        print(f"  {label:<16} {len(found):>3} candidates", file=sys.stderr)
        for movie_id, film in found.items():
            films_by_id[movie_id] = film
            tiers_by_id.setdefault(movie_id, []).append(key)

    print(f"  {'distinct':<16} {len(films_by_id):>3} candidates", file=sys.stderr)

    # The runtime that decides it comes from the details endpoint; discover's
    # own filter lets TV specials through.
    with ThreadPoolExecutor(max_workers=8) as pool:
        runtimes = dict(zip(films_by_id, pool.map(runtime_of, films_by_id)))

    entries = []
    dropped = []
    for movie_id, film in films_by_id.items():
        if runtimes[movie_id] >= MIN_RUNTIME:
            entries.append(
                {
                    "type": "movie",
                    "tmdb_id": movie_id,
                    "title": film["title"],
                    "date": film.get("release_date") or "",
                    "tiers": sorted(tiers_by_id[movie_id]),
                }
            )
        else:
            dropped.append(f'{film["title"]} ({runtimes[movie_id]}m)')

    entries.sort(key=lambda e: (e["date"] or "9999", e["title"]))
    print(f"  {'features':<16} {len(entries):>3} kept", file=sys.stderr)
    print(f"  dropped as shorts/specials: {', '.join(sorted(dropped))}", file=sys.stderr)

    print(
        json.dumps(
            {
                "name": "Animation",
                "broad": True,
                "tiers": [
                    {
                        "key": "all",
                        "label": "Everything",
                        "blurb": "every animated feature here, in release order",
                    }
                ]
                + [
                    {"key": key, "label": label, "blurb": blurb}
                    for key, label, blurb, _ in STUDIOS
                ],
                "entries": entries,
            },
            indent=1,
        )
    )


if __name__ == "__main__":
    main()
