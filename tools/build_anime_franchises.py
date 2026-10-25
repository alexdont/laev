#!/usr/bin/env python3
"""Build the curated anime franchise lists in priv/franchises.json from TMDB.

    tools/build_anime_franchises.py $TMDB_API_KEY > /tmp/anime.json

Why these exist: TMDB files a franchise's parts as unrelated shows. Bleach is
one show (30984) and Thousand-Year Blood War is another (154494), so opening
either shows half the story and neither shows the four films. Naruto, Shippuden
and Boruto are three shows. Fate is nine. Putting them under one name is what
the curated lists are for, and the same reason Marvel and Star Wars are here.

Nothing is typed from memory. Every title below is a *query*, resolved against
TMDB and checked for type, and for year where two things share a name; anything
that does not resolve is reported and left out rather than guessed at. Films
that TMDB already collects are taken from the collection, so a franchise's
fifteen films are one line here rather than fifteen.

TV series are listed one season at a time with the date that season first aired,
which is how the file keeps release order honest across a franchise whose parts
arrived over twenty years. TMDB's own seasons are kept as TMDB has them: where
it has merged two cours into one season the app sorts that out, and splitting
them here would fight it.
"""
import json, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

KEY = sys.argv[1]
API = "https://api.themoviedb.org/3"

# name, tiers (or None), and what to look for. A query is (title, year) — the
# year is only given where it disambiguates, and is checked within a year
# either way because TMDB and MAL disagree about what "first aired" means for
# a show that premiered on New Year's Eve.
#
# "collections" expand to every part TMDB files in them, which is how the long
# film runs stay short here.
F = [
    ("Attack on Titan", None, {
        "tv": [("Attack on Titan", 2013)],
        "movies": [("Attack on Titan: Crimson Bow and Arrow", 2014),
                   ("Attack on Titan: Wings of Freedom", 2015),
                   ("Attack on Titan: Roar of Awakening", 2018),
                   ("Attack on Titan: Chronicle", 2020),
                   ("Attack on Titan: The Last Attack", 2024)],
    }),
    ("My Hero Academia", None, {
        "tv": [("My Hero Academia", 2016)],
        "collections": ["My Hero Academia"],
    }),
    ("Demon Slayer", None, {
        "tv": [("Demon Slayer: Kimetsu no Yaiba", 2019)],
        "movies": [("Demon Slayer: Kimetsu no Yaiba - The Movie: Mugen Train", 2020),
                   ("Demon Slayer: Kimetsu no Yaiba Infinity Castle", 2025)],
    }),
    ("Sword Art Online", None, {
        # Alicization is season 3 of the same show on TMDB, not a show of its own.
        "tv": [("Sword Art Online", 2012),
               ("Sword Art Online Alternative: Gun Gale Online", 2018)],
        "movies": [("Sword Art Online: Ordinal Scale", 2017),
                   ("Sword Art Online: Progressive - Aria of a Starless Night", 2021),
                   ("Sword Art Online: Progressive - Scherzo of Deep Night", 2022)],
    }),
    ("Fate", None, {
        "tv": [("Fate/stay night", 2006), ("Fate/Zero", 2011),
               ("Fate/stay night: Unlimited Blade Works", 2014),
               ("Fate/Apocrypha", 2017), ("Fate/Extra Last Encore", 2018),
               ("Fate/Grand Order Absolute Demonic Front: Babylonia", 2019),
               ("Fate/kaleid liner Prisma Illya", 2013)],
        "movies": [("Fate/stay night: Heaven's Feel I. Presage Flower", 2017),
                   ("Fate/stay night: Heaven's Feel II. Lost Butterfly", 2019),
                   ("Fate/stay night: Heaven's Feel III. Spring Song", 2020),
                   ("Fate/Grand Order: The Movie - Divine Realm of the Round Table: Camelot Paladin; Agateram", 2021)],
    }),
    ("Naruto", [("series", "Series", "Naruto, Shippuden and Boruto in order"),
                ("movies", "Movies", "every Naruto film")], {
        "tv": [("Naruto", 2002), ("Naruto Shippūden", 2007),
               ("Boruto: Naruto Next Generations", 2017)],
        "collections": ["Naruto"],
    }),
    ("Monogatari", None, {
        # TMDB keeps the whole Monogatari run as one show with a season per arc.
        "tv": [("Monogatari", 2009)],
        "movies": [("Kizumonogatari Part 1: Tekketsu", 2016)],
    }),
    ("JoJo's Bizarre Adventure", None, {
        "tv": [("JoJo's Bizarre Adventure", 2012)],
        "movies": [("JoJo's Bizarre Adventure: Phantom Blood", 2007)],
    }),
    ("Haikyu!!", None, {
        "tv": [("Haikyu!!", 2014)],
        "movies": [("Haikyu!! The Dumpster Battle", 2024)],
    }),
    ("Tokyo Ghoul", None, {
        # :re is seasons 3 and 4 of the same show on TMDB.
        "tv": [("Tokyo Ghoul", 2014)],
    }),
    ("One Punch Man", None, {
        "tv": [("One Punch Man", 2015)],
    }),
    ("KonoSuba", None, {
        "tv": [("KonoSuba: God's Blessing on This Wonderful World!", 2016),
               ("KonoSuba: An Explosion on This Wonderful World!", 2023)],
        "movies": [("KonoSuba: God's Blessing on This Wonderful World! Legend of Crimson", 2019)],
    }),
    ("Re:Zero", None, {
        "tv": [("Re:ZERO -Starting Life in Another World-", 2016)],
        "movies": [("Re:ZERO -Starting Life in Another World- The Frozen Bond", 2019)],
    }),
    ("Jujutsu Kaisen", None, {
        "tv": [("Jujutsu Kaisen", 2020)],
        "movies": [("Jujutsu Kaisen 0", 2021)],
    }),
    ("Food Wars", None, {
        "tv": [("Food Wars! Shokugeki no Soma", 2015)],
    }),
    ("The Seven Deadly Sins", None, {
        "tv": [("The Seven Deadly Sins", 2014),
               ("The Seven Deadly Sins: Four Knights of the Apocalypse", 2023)],
        "movies": [("The Seven Deadly Sins: Prisoners of the Sky", 2018),
                   ("The Seven Deadly Sins: Cursed by Light", 2021),
                   ("The Seven Deadly Sins: Grudge of Edinburgh Part 1", 2022)],
    }),
    ("Fullmetal Alchemist", None, {
        "tv": [("Fullmetal Alchemist", 2003), ("Fullmetal Alchemist: Brotherhood", 2009)],
        "movies": [("Fullmetal Alchemist: The Conqueror of Shamballa", 2005),
                   ("Fullmetal Alchemist: The Sacred Star of Milos", 2011)],
    }),
    ("Evangelion", None, {
        "tv": [("Neon Genesis Evangelion", 1995)],
        "collections": ["Rebuild of Evangelion"],
        "movies": [("Neon Genesis Evangelion: The End of Evangelion", 1997),
                   ("Neon Genesis Evangelion: Death & Rebirth", 1997)],
    }),
    ("Steins;Gate", None, {
        "tv": [("Steins;Gate", 2011), ("Steins;Gate 0", 2018)],
        "movies": [("Steins;Gate: The Movie - Load Region of Déjà Vu", 2013)],
    }),
    ("Dr. Stone", None, {
        "tv": [("Dr. STONE", 2019)],
    }),
    ("Kaguya-sama: Love Is War", None, {
        "tv": [("Kaguya-sama: Love Is War", 2019)],
        "movies": [("Kaguya-sama: Love Is War -The First Kiss That Never Ends-", 2022)],
    }),
    ("Dragon Ball", [("series", "Series", "every Dragon Ball series in order"),
                     ("movies", "Movies", "every Dragon Ball film")], {
        "tv": [("Dragon Ball", 1986), ("Dragon Ball Z", 1989), ("Dragon Ball GT", 1996),
               ("Dragon Ball Super", 2015), ("Dragon Ball Daima", 2024),
               ("Dragon Ball Z Kai", 2009)],
        "collections": ["Dragon Ball"],
    }),
    ("Mob Psycho 100", None, {
        "tv": [("Mob Psycho 100", 2016)],
    }),
    ("Code Geass", None, {
        "tv": [("Code Geass: Lelouch of the Rebellion", 2006),
               ("Code Geass: Akito the Exiled", 2012)],
        "movies": [("Code Geass: Lelouch of the Re;surrection", 2019)],
    }),
    ("That Time I Got Reincarnated as a Slime", None, {
        "tv": [("That Time I Got Reincarnated as a Slime", 2018)],
        "movies": [("That Time I Got Reincarnated as a Slime the Movie: Scarlet Bond", 2022)],
    }),
    ("Overlord", None, {
        "tv": [("Overlord", 2015)],
        "movies": [("Overlord: The Sacred Kingdom", 2024)],
    }),
    ("Mushoku Tensei", None, {
        "tv": [("Mushoku Tensei: Jobless Reincarnation", 2021)],
    }),
    ("DanMachi", None, {
        "tv": [("Is It Wrong to Try to Pick Up Girls in a Dungeon?", 2015),
               ("Sword Oratoria: Is It Wrong to Try to Pick Up Girls in a Dungeon? On the Side", 2017)],
        "movies": [("Is It Wrong to Try to Pick Up Girls in a Dungeon?: Arrow of the Orion", 2019)],
    }),
    ("High School DxD", None, {
        "tv": [("High School DxD", 2012)],
    }),
    ("Noragami", None, {
        "tv": [("Noragami", 2014)],
    }),
    ("Spy x Family", None, {
        "tv": [("SPY x FAMILY", 2022)],
        "movies": [("Spy x Family Code: White", 2023)],
    }),
    ("Bleach", None, {
        # Thousand-Year Blood War is season 2 of Bleach on TMDB, not a separate
        # show: tv 154494, which the brief named, is Lycoris Recoil.
        "tv": [("Bleach", 2004)],
        "collections": ["Bleach"],
    }),
    ("Bungo Stray Dogs", None, {
        "tv": [("Bungo Stray Dogs", 2016)],
        "movies": [("Bungo Stray Dogs: Dead Apple", 2018)],
    }),
    ("Hunter x Hunter", None, {
        "tv": [("Hunter x Hunter", 1999), ("Hunter x Hunter", 2011)],
        "movies": [("Hunter x Hunter: Phantom Rouge", 2013),
                   ("Hunter x Hunter: The Last Mission", 2013)],
    }),
    ("Assassination Classroom", None, {
        "tv": [("Assassination Classroom", 2015)],
        "movies": [("Assassination Classroom: 365 Days", 2016)],
    }),
    ("Violet Evergarden", None, {
        "tv": [("Violet Evergarden", 2018)],
        "movies": [("Violet Evergarden: Eternity and the Auto Memory Doll", 2019),
                   ("Violet Evergarden: The Movie", 2020)],
    }),
    ("No Game No Life", None, {
        "tv": [("No Game No Life", 2014)],
        "movies": [("No Game No Life: Zero", 2017)],
    }),
    ("Fairy Tail", None, {
        "tv": [("Fairy Tail", 2009), ("Fairy Tail: 100 Years Quest", 2024)],
        "movies": [("Fairy Tail: Phoenix Priestess", 2012),
                   ("Fairy Tail: Dragon Cry", 2017)],
    }),
    ("The Rising of the Shield Hero", None, {
        "tv": [("The Rising of the Shield Hero", 2019)],
    }),
    ("Gintama", None, {
        "tv": [("Gintama", 2006)],
        "movies": [("Gintama: The Movie", 2010),
                   ("Gintama: The Final Chapter - Be Forever Yorozuya", 2013),
                   ("Gintama: The Very Final", 2021)],
    }),
    ("The Promised Neverland", None, {
        "tv": [("The Promised Neverland", 2019)],
    }),
    ("Psycho-Pass", None, {
        "tv": [("PSYCHO-PASS", 2012)],
        "movies": [("Psycho-Pass: The Movie", 2015)],
    }),
    ("One Piece", [("series", "Series", "the series, season by season"),
                   ("movies", "Movies", "every One Piece film")], {
        "tv": [("One Piece", 1999)],
        "collections": ["One Piece"],
    }),
    ("Blue Exorcist", None, {
        "tv": [("Blue Exorcist", 2011)],
        "movies": [("Blue Exorcist: The Movie", 2012)],
    }),
    ("Classroom of the Elite", None, {
        "tv": [("Classroom of the Elite", 2017)],
    }),
    ("Fire Force", None, {
        "tv": [("Fire Force", 2019)],
    }),
    ("Vinland Saga", None, {
        "tv": [("Vinland Saga", 2019)],
    }),
    ("Made in Abyss", None, {
        "tv": [("Made in Abyss", 2017)],
        "movies": [("Made in Abyss: Journey's Dawn", 2019),
                   ("Made in Abyss: Wandering Twilight", 2019),
                   ("Made in Abyss: Dawn of the Deep Soul", 2020)],
    }),
    ("Chainsaw Man", None, {
        "tv": [("Chainsaw Man", 2022)],
        "movies": [("Chainsaw Man - The Movie: Reze Arc", 2025)],
    }),
    ("Frieren", None, {
        "tv": [("Frieren: Beyond Journey's End", 2023)],
    }),
    ("Solo Leveling", None, {
        "tv": [("Solo Leveling", 2024)],
        "movies": [("Solo Leveling -ReAwakening-", 2024)],
    }),
    ("Cowboy Bebop", None, {
        "tv": [("Cowboy Bebop", 1998)],
        "movies": [("Cowboy Bebop: The Movie", 2001)],
    }),
    ("A Certain Magical Index", None, {
        "tv": [("A Certain Magical Index", 2008), ("A Certain Scientific Railgun", 2009),
               ("A Certain Scientific Accelerator", 2019)],
        "movies": [("A Certain Magical Index: The Movie - The Miracle of Endymion", 2013)],
    }),
    ("Dandadan", None, {
        "tv": [("Dan Da Dan", 2024)],
    }),
    ("Black Clover", None, {
        "tv": [("Black Clover", 2017)],
        "movies": [("Black Clover: Sword of the Wizard King", 2023)],
    }),
    ("Death Note", None, {
        "tv": [("Death Note", 2006)],
        "collections": ["Death Note"],
    }),
    ("Detective Conan", [("series", "Series", "the series, season by season"),
                         ("movies", "Movies", "every Detective Conan film")], {
        "tv": [("Case Closed", 1996)],
        "collections": ["Detective Conan"],
    }),
    ("Pokémon", [("series", "Series", "every Pokémon series in order"),
                 ("movies", "Movies", "every Pokémon film")], {
        "tv": [("Pokémon", 1997), ("Pokémon Horizons: The Series", 2023)],
        "collections": ["Pokémon"],
    }),
    ("Yu-Gi-Oh!", [("series", "Series", "every Yu-Gi-Oh! series in order"),
                   ("movies", "Movies", "the Yu-Gi-Oh! films")], {
        "tv": [("Yu-Gi-Oh!", 2000), ("Yu-Gi-Oh! GX", 2004), ("Yu-Gi-Oh! 5D's", 2008),
               ("Yu-Gi-Oh! Zexal", 2011), ("Yu-Gi-Oh! Arc-V", 2014),
               ("Yu-Gi-Oh! VRAINS", 2017), ("Yu-Gi-Oh! Sevens", 2020),
               ("Yu-Gi-Oh! Go Rush!!", 2022)],
        "movies": [("Yu-Gi-Oh! The Dark Side of Dimensions", 2016),
                   ("Yu-Gi-Oh! The Movie: Pyramid of Light", 2004)],
    }),
    ("Soul Eater", None, {
        "tv": [("Soul Eater", 2008), ("Soul Eater Not!", 2014)],
    }),
    ("Tokyo Revengers", None, {
        "tv": [("Tokyo Revengers", 2021)],
    }),
    ("Mobile Suit Gundam", [("series", "Series", "the Gundam series, in order"),
                            ("movies", "Movies", "the Gundam films")], {
        "tv": [("Mobile Suit Gundam", 1979), ("Mobile Suit Zeta Gundam", 1985),
               ("Mobile Suit Gundam Wing", 1995), ("Mobile Suit Gundam SEED", 2002),
               ("Mobile Suit Gundam 00", 2007), ("Mobile Suit Gundam: Iron-Blooded Orphans", 2015),
               ("Mobile Suit Gundam: The Witch from Mercury", 2022),
               ("Mobile Suit Gundam Unicorn RE:0096", 2016),
               ("Mobile Suit Gundam: Requiem for Vengeance", 2024),
               ("Mobile Suit Gundam GQuuuuuuX", 2025)],
        "movies": [("Mobile Suit Gundam: Char's Counterattack", 1988),
                   ("Mobile Suit Gundam F91", 1991),
                   ("Mobile Suit Gundam: Hathaway's Flash", 2021),
                   ("Mobile Suit Gundam SEED Freedom", 2024)],
    }),
]


def get(path, **params):
    params["api_key"] = KEY
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return json.load(response)
        except Exception:
            time.sleep(0.6 * (attempt + 1))
    return {}


def resolve(query, kind):
    """One title to one TMDB row, or None — never a guess."""
    title, year = query
    key = "first_air_date" if kind == "tv" else "release_date"
    hits = get(f"search/{kind}", query=title).get("results") or []

    def score(hit):
        name = (hit.get("name") or hit.get("title") or "").lower()
        got = (hit.get(key) or "")[:4]
        exact = name == title.lower()
        close = title.lower() in name or name in title.lower()
        same_year = bool(year) and got == str(year)
        near_year = bool(year) and got.isdigit() and abs(int(got) - year) <= 1
        return (exact and same_year, exact and near_year, same_year, exact, close, near_year)

    best = max(hits, key=score, default=None)
    if not best:
        return None

    # A year was given because it matters: a hit two years off is a different
    # show with the same name, which is exactly what must not be written down.
    got = (best.get(key) or "")[:4]
    if year and got.isdigit() and abs(int(got) - year) > 1:
        return None
    if year and not got.isdigit():
        return None

    return {"type": kind, "tmdb_id": best["id"],
            "title": best.get("name") or best.get("title"), "date": best.get(key) or ""}


def seasons_of(show):
    """A TV show as one entry per aired season, the way the file wants it."""
    details = get(f"tv/{show['tmdb_id']}")
    out = []

    for season in details.get("seasons") or []:
        if (season.get("season_number") or 0) < 1:
            continue
        if not (season.get("air_date") or ""):
            continue
        out.append({"type": "tv", "tmdb_id": show["tmdb_id"],
                    "season": season["season_number"], "title": details.get("name"),
                    "date": season["air_date"]})

    # A show TMDB lists with no dated season still belongs in the list.
    return out or [{"type": "tv", "tmdb_id": show["tmdb_id"], "season": 1,
                    "title": details.get("name"), "date": show["date"]}]


def collection_parts(name):
    hits = get("search/collection", query=name).get("results") or []
    if not hits:
        return [], f"collection not found: {name}"

    best = next((h for h in hits if (h.get("name") or "").lower().startswith(name.lower())), hits[0])
    parts = get(f"collection/{best['id']}").get("parts") or []
    return [{"type": "movie", "tmdb_id": p["id"], "title": p.get("title"),
             "date": p.get("release_date") or ""} for p in parts if p.get("release_date")], None


def build(entry):
    name, tiers, spec = entry
    problems, rows = [], []

    for query in spec.get("tv", []):
        found = resolve(query, "tv")
        if found:
            rows.extend(seasons_of(found))
        else:
            problems.append(f"{name}: no tv match for {query[0]} ({query[1]})")

    for query in spec.get("movies", []):
        found = resolve(query, "movie")
        if found and found["date"]:
            rows.append(found)
        else:
            problems.append(f"{name}: no film match for {query[0]} ({query[1]})")

    for collection in spec.get("collections", []):
        parts, problem = collection_parts(collection)
        rows.extend(parts)
        if problem:
            problems.append(f"{name}: {problem}")

    # One row per (type, id, season); a film that is in a collection and named
    # explicitly appears once.
    seen, unique = set(), []
    for row in rows:
        key = (row["type"], row["tmdb_id"], row.get("season"))
        if key not in seen:
            seen.add(key)
            unique.append(row)

    unique.sort(key=lambda r: (r["date"] or "9999", r["type"], r.get("season") or 0))

    if tiers:
        for row in unique:
            row["tiers"] = ["series" if row["type"] == "tv" else "movies"]

    franchise = {"name": name, "entries": unique}
    if tiers:
        franchise["tiers"] = [{"key": k, "label": l, "blurb": b} for k, l, b in tiers]

    return franchise, problems


with ThreadPoolExecutor(max_workers=6) as pool:
    results = list(pool.map(build, F))

franchises = [f for f, _ in results]
problems = [p for _, ps in results for p in ps]

print(json.dumps({"franchises": franchises, "problems": problems}, indent=1, ensure_ascii=False))
