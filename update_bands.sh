#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Refreshes bands.txt from Wikidata: musical groups tagged with one of the
# genres in WIKIDATA_GENRE_QIDS (see .env.example), ranked by sitelink count
# (a decent cross-language popularity proxy), CC0-licensed so there's no
# attribution/ToS concern. Meant to run occasionally (e.g. daily via cron),
# NOT on every post_song_quote.sh run - Wikidata's public endpoint asks for a
# descriptive User-Agent and isn't meant for frequent hammering.
[ -f ".env" ] && source ".env"

# Default: rock, heavy metal, punk rock, hard rock. Look up a genre's QID by
# searching for it on https://www.wikidata.org and reading the "Q..." out of
# the URL, or via https://www.wikidata.org/wiki/Special:EntityData/QXXX.json
: "${WIKIDATA_GENRE_QIDS:=Q11399,Q38848,Q3071,Q83270}"

BANDS_FILE="bands.txt"
# Optional, untracked, one-name-per-line list of bands to never include (e.g.
# acts tied to real-world criminal/extremist notoriety that slipped in via
# genre tagging). Not required to exist.
EXCLUDE_FILE="bands_exclude.txt"
MIN_SITELINKS=25
LIMIT=200

GENRE_VALUES=$(echo "$WIKIDATA_GENRE_QIDS" | tr ',' '\n' | sed 's/^/wd:/' | tr '\n' ' ')

# One row per band: name, genre and country of origin, tab-separated - the genre
# and country are what post_song_quote.sh shows alongside the quote. Both are
# OPTIONAL: a band with neither still makes the list, just with empty columns.
#
# A band usually carries several genres in Wikidata, and the post only has room
# for one. Picking it by the genre's own sitelink count gives the best-known,
# most recognizable one (Queen -> "rock music", Ramones -> "punk rock") - any
# arbitrary pick instead turns up oddities like Queen as "traditional heavy
# metal". SPARQL has no argmax, hence the trick: each genre becomes the string
# "<sitelinks>|<item>", the largest of those wins (the count is offset to a
# fixed width so the comparison stays numeric), and the item is cut back out.
#
# The aggregation sits in a subquery and works on the genre/country ITEMS, with
# the label service resolving names for the 200 survivors afterwards.
# Aggregating over the labels directly would have to join labels in for every
# band matching the genre filter, not just the top 200 - which makes the query
# several times slower and gets it answered with a 502.
QUERY="
SELECT ?bandLabel ?genreLabel ?countryLabel ?sitelinks WHERE {
  {
    SELECT ?band ?sitelinks (MAX(?rankedGenre) AS ?topGenre) (MIN(?c) AS ?country) WHERE {
      ?band wdt:P31 wd:Q215380 .
      ?band wdt:P136/wdt:P279* ?seedGenre .
      VALUES ?seedGenre { ${GENRE_VALUES} }
      ?band wikibase:sitelinks ?sitelinks .
      FILTER(?sitelinks > ${MIN_SITELINKS})
      OPTIONAL {
        ?band wdt:P136 ?g .
        ?g wikibase:sitelinks ?gsl .
        BIND(CONCAT(STR(100000 + ?gsl), \"|\", STR(?g)) AS ?rankedGenre)
      }
      OPTIONAL { ?band wdt:P495 ?c }
    }
    GROUP BY ?band ?sitelinks
    ORDER BY DESC(?sitelinks)
    LIMIT ${LIMIT}
  }
  # A band without any genre leaves ?topGenre unbound, STRAFTER then fails and
  # ?genre simply stays unbound too - which is what the empty column wants.
  BIND(IRI(STRAFTER(?topGenre, \"|\")) AS ?genre)
  SERVICE wikibase:label { bd:serviceParam wikibase:language \"en\". }
}"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if ! curl -fsS --max-time 180 -G "https://query.wikidata.org/sparql" \
  --data-urlencode "query=${QUERY}" \
  -H "Accept: application/sparql-results+json" \
  -H "User-Agent: song-quote-bot/1.0 (https://github.com/schmidt-software/song-quote-bot)" \
  -o "$TMP"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Wikidata-Abfrage fehlgeschlagen, bands.txt unveraendert" >&2
  exit 0
fi

# Entities without an English label come back as a raw QID (e.g. "Q44190")
# instead of a name - a band like that is dropped entirely, a genre or country
# like that just leaves its column empty.
ROWS=$(jq -r '
  def named: if (. // "") | test("^Q[0-9]+$") then "" else (. // "") end;
  .results.bindings[]
  | select((.bandLabel.value | test("^Q[0-9]+$")) | not)
  | [.bandLabel.value, (.genreLabel.value | named), (.countryLabel.value | named)] | @tsv' "$TMP" \
  | sort -u | awk -F'\t' '!seen[$1]++')

if [ -z "$ROWS" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Wikidata-Antwort leer, bands.txt unveraendert" >&2
  exit 0
fi

# The exclude list holds plain band names, so it's matched against the first
# column only - a band is dropped no matter which genre/country it came with.
if [ -f "$EXCLUDE_FILE" ]; then
  ROWS=$(printf '%s\n' "$ROWS" | awk -F'\t' 'NR == FNR { if ($0 != "") excluded[$0] = 1; next } !($1 in excluded)' "$EXCLUDE_FILE" -)
fi

printf '%s\n' "$ROWS" > "${BANDS_FILE}.tmp" && mv "${BANDS_FILE}.tmp" "$BANDS_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) bands.txt aktualisiert ($(printf '%s\n' "$ROWS" | wc -l) Bands)"
