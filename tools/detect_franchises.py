#!/usr/bin/env python3
"""Flag movie franchises that TMDB's collections group badly.

Two symptoms, both visible without knowing the franchise exists:
  SPLIT      films of one franchise fall into more than one collection
  INCOMPLETE a collection exists, but real films of the same franchise sit outside it
  MISSING    several films share a franchise name and none are in a collection

The noise all comes from one place: things that look like a franchise but
aren't. Same-title films from other decades, making-ofs and premiere specials,
and generic words ("fury", "fall", "weapons") that match unrelated titles. So
candidates must be real features by vote count, must not be documentaries, and
a searched film only counts if its title actually starts with the franchise
name — which is what stops "fury" dragging in Shazam.
"""
import json, os, re, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

KEY = sys.argv[1]
PAGES = int(sys.argv[2]) if len(sys.argv) > 2 else 15
SOURCE = sys.argv[3] if len(sys.argv) > 3 else "popular"
MIN_VOTES = 80
DOCUMENTARY = 99
CACHE_PATH = os.path.join(os.path.dirname(__file__), "tmdb_cache.json")
CACHE = json.load(open(CACHE_PATH)) if os.path.exists(CACHE_PATH) else {}


def api(path, **params):
    params["api_key"] = KEY
    url = "https://api.themoviedb.org/3%s?%s" % (path, urllib.parse.urlencode(params))
    ck = url.replace(KEY, "KEY")
    if ck in CACHE:
        return CACHE[ck]
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                out = json.load(r)
            CACHE[ck] = out
            return out
        except Exception:
            if attempt == 2:
                return {}
    return {}


STOP = re.compile(r"^(the|a|an)\s+", re.I)
ROMAN = re.compile(r"\s+(part\s+)?(chapter\s+)?(i{1,3}|iv|v|vi{1,3}|ix|x{1,2})$", re.I)
# a sequel/spin-off title is the franchise name plus something; a promo is not
NOT_A_FILM = re.compile(r"making of|premiere|behind the scenes|red carpet|assembled|remix|\bspecial\b", re.I)


def norm(s):
    return STOP.sub("", re.sub(r"[^a-z0-9 ]+", " ", s.lower())).strip()


def franchise_key(title):
    t = title
    for sep in (":", " - ", " – ", " —"):
        if sep in t:
            t = t.split(sep)[0]
    t = ROMAN.sub("", t)
    t = re.sub(r"\s+(part\s+)?\d+$", "", t, flags=re.I)
    return norm(t)


def real_film(m):
    return (
        m.get("vote_count", 0) >= MIN_VOTES
        and not m.get("video")
        and DOCUMENTARY not in (m.get("genre_ids") or [])
        and not NOT_A_FILM.search(m.get("title", ""))
    )


def details(movie_id):
    return api("/movie/%s" % movie_id)


def collection_of(movie_id):
    c = details(movie_id).get("belongs_to_collection")
    return c["name"] if c else None


def feature_length(movie_id):
    """Shorts, TV specials and alternate cuts pad the queue without being films
    anyone would pick from a franchise list. Runtime is already fetched."""
    return (details(movie_id).get("runtime") or 0) >= 60


def main():
    films, seen = [], set()
    for p in range(1, PAGES + 1):
        page = (api("/movie/popular", page=p) if SOURCE == "popular"
                else api("/discover/movie", page=p, sort_by="vote_count.desc"))
        for f in page.get("results", []):
            if f.get("title") and f["id"] not in seen and real_film(f) and feature_length(f["id"]):
                seen.add(f["id"])
                films.append(f)
    print("scanned %d distinct feature films" % len(films), file=sys.stderr)

    with ThreadPoolExecutor(max_workers=8) as ex:
        for f, c in zip(films, ex.map(lambda f: collection_of(f["id"]), films)):
            f["collection"] = c

    groups = {}
    for f in films:
        groups.setdefault(franchise_key(f["title"]), []).append(f)

    # one film is not a franchise; neither is a name so short it matches anything
    candidates = {k: v for k, v in groups.items() if k and len(k) >= 4 and len(v) > 1}

    def franchise_films(name):
        """Films whose title really belongs to this franchise, with their collections."""
        res = [m for m in api("/search/movie", query=name).get("results", [])[:10] if real_film(m)]
        res = [m for m in res if norm(m["title"]).startswith(name) and feature_length(m["id"])]
        with ThreadPoolExecutor(max_workers=6) as ex:
            cols = list(ex.map(lambda m: collection_of(m["id"]), res))
        return [(m["title"], c) for m, c in zip(res, cols)]

    findings = []
    for name, members in candidates.items():
        pop = max(m.get("popularity", 0) for m in members)
        pairs = {(m["title"], m["collection"]) for m in members} | set(franchise_films(name))
        cols = {c for _, c in pairs if c}
        outside = sorted(t for t, c in pairs if not c)

        if len(cols) > 1:
            why, detail = "SPLIT", "%d collections: %s" % (len(cols), ", ".join(sorted(cols))[:88])
        elif cols and outside:
            why, detail = "INCOMPLETE", "outside %s: %s" % (list(cols)[0], ", ".join(outside)[:76])
        elif not cols and len({t for t, _ in pairs}) > 1:
            why, detail = "MISSING", "no collection: %s" % ", ".join(sorted({t for t, _ in pairs}))[:78]
        else:
            continue
        findings.append((pop, name, why, detail))

    json.dump(CACHE, open(CACHE_PATH, "w"))
    findings.sort(key=lambda r: -r[0])
    print("\n%-24s %-11s %s" % ("franchise", "problem", "evidence"))
    for _, name, why, detail in findings:
        print("%-24s %-11s %s" % (name[:24], why, detail))
    print("\n%d candidate franchises, %d flagged" % (len(candidates), len(findings)), file=sys.stderr)


main()

# Usage:
#   tools/detect_franchises.py "$TMDB_API_KEY" 15 top      # 300 most-voted of all time
#   tools/detect_franchises.py "$TMDB_API_KEY" 15 popular  # 300 trending right now
#
# Both passes are worth running: they surface different franchises. Responses
# are cached next to the script, so re-runs only pay for what is new.
