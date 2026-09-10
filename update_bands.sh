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

QUERY="
SELECT DISTINCT ?bandLabel ?sitelinks WHERE {
  ?band wdt:P31 wd:Q215380 .
  ?band wdt:P136/wdt:P279* ?genre .
  VALUES ?genre { ${GENRE_VALUES} }
  ?band wikibase:sitelinks ?sitelinks .
  FILTER(?sitelinks > ${MIN_SITELINKS})
  SERVICE wikibase:label { bd:serviceParam wikibase:language \"en\". }
}
ORDER BY DESC(?sitelinks)
LIMIT ${LIMIT}"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if ! curl -fsS -G "https://query.wikidata.org/sparql" \
  --data-urlencode "query=${QUERY}" \
  -H "Accept: application/sparql-results+json" \
  -H "User-Agent: song-quote-bot/1.0 (https://github.com/schmidt-software/song-quote-bot)" \
  -o "$TMP"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Wikidata-Abfrage fehlgeschlagen, bands.txt unveraendert" >&2
  exit 0
fi

# A handful of entities have no English label and come back as a raw QID
# (e.g. "Q44190") instead of a name - drop those rather than posting a QID as
# a "band".
NAMES=$(jq -r '.results.bindings[].bandLabel.value | select(test("^Q[0-9]+$") | not)' "$TMP" | sort -u)

if [ -z "$NAMES" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Wikidata-Antwort leer, bands.txt unveraendert" >&2
  exit 0
fi

if [ -f "$EXCLUDE_FILE" ]; then
  NAMES=$(comm -23 <(printf '%s\n' "$NAMES") <(sort -u "$EXCLUDE_FILE"))
fi

printf '%s\n' "$NAMES" > "${BANDS_FILE}.tmp" && mv "${BANDS_FILE}.tmp" "$BANDS_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) bands.txt aktualisiert ($(printf '%s\n' "$NAMES" | wc -l) Bands)"
