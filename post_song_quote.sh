#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# cron appends this run's output to the log file (see crontab). Once we're
# done writing to it, trim it back down to the last MAX_LOG_ENTRIES lines so
# the file can't grow forever - oldest entries drop off first.
LOG_FILE="post_song_quote.log"
MAX_LOG_ENTRIES=50
trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  local tmp
  tmp=$(mktemp "${LOG_FILE}.XXXXXX")
  tail -n "$MAX_LOG_ENTRIES" "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}
trap trim_log EXIT

# Local, untracked config (see .env.example) - holds your Ollama endpoint etc.
# DRY_RUN is picked up before that, see where it is evaluated below.
DRY_RUN_ARG="${DRY_RUN-}"
[ -f ".env" ] && source ".env"

: "${OLLAMA_URL:?Set OLLAMA_URL (e.g. in .env) to your Ollama server, e.g. http://localhost:11434/api/chat}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL (e.g. in .env) to the model to use, e.g. llama3.1:8b}"
# Context window for every Ollama request. It has to hold the whole prompt
# (instructions + lyrics + recent-quote list). Ollama silently truncates a longer
# prompt, keeping only its END - which drops the lyrics and the actual task and
# leaves the model working from whatever is left. Server defaults are small
# (2k-4k) and can shrink further under memory pressure, so pin it here. A
# measured worst case (longest lyrics plus the recent-quote list) is well under
# 2k tokens, so the default below has room to spare - it guards against a small
# server default, not against the prompt itself getting big.
: "${OLLAMA_NUM_CTX:=8192}"
case "$OLLAMA_NUM_CTX" in
  ''|*[!0-9]*) echo "OLLAMA_NUM_CTX muss eine positive Zahl sein: '$OLLAMA_NUM_CTX'" >&2; exit 1 ;;
esac
# How long Ollama keeps the model in memory after answering. The server default
# is 5 minutes, so a run that comes around once a day always pays a full cold
# load - tens of seconds of silence before the first answer, and with a large
# model enough to hit the 90s request timeout further down and lose the attempt
# outright. Keeping it resident costs the server memory in between, so it stays
# configurable: "0" unloads immediately, "-1" keeps it loaded indefinitely.
: "${OLLAMA_KEEP_ALIVE:=30m}"

: "${POST_TARGETS:=mastodon}"

# A dry run does everything a real one does - pick, fetch lyrics, extract and
# verify the quote, look up the album - and then prints the finished post
# instead of publishing it, leaving the database untouched. Testing a change to
# the script otherwise means posting to the live account for real, once per run,
# and cleaning up afterwards.
#
# A value passed on the command line (DRY_RUN=1 ./post_song_quote.sh) wins over
# whatever the config file sets: sourcing it would otherwise silently overwrite
# the variable, and a "dry run" that quietly posts for real is the one failure
# this switch must never have.
if [ -n "$DRY_RUN_ARG" ]; then
  DRY_RUN="$DRY_RUN_ARG"
fi
: "${DRY_RUN:=0}"
case "$DRY_RUN" in
  0|1) ;;
  *) echo "DRY_RUN muss 0 oder 1 sein: '$DRY_RUN'" >&2; exit 1 ;;
esac

# Validate every configured target up front, before doing any (costly) LLM work.
IFS=',' read -ra TARGET_LIST <<< "$POST_TARGETS"
for t in "${TARGET_LIST[@]}"; do
  case "$t" in
    mastodon)
      # A dry run never reaches the platform, so it must not insist on
      # credentials either - that way a fresh checkout can be tried end to end
      # before any account exists. The target NAME is still validated below.
      if [ "$DRY_RUN" = "0" ]; then
        : "${MASTODON_URL:?Set MASTODON_URL (e.g. in .env) to your Mastodon instance, e.g. https://mastodon.social}"
        : "${MASTODON_ACCESS_TOKEN:?Set MASTODON_ACCESS_TOKEN (e.g. in .env) - create one under Settings > Development > New Application with the write:statuses scope}"
      fi
      ;;
    *)
      echo "Unbekanntes POST_TARGET: '$t' (unterstützt: mastodon)" >&2
      exit 1
      ;;
  esac
done

post_to_mastodon() {
  local text="$1" response
  if ! response=$(curl -sS --max-time 30 -X POST "${MASTODON_URL%/}/api/v1/statuses" \
    -H "Authorization: Bearer ${MASTODON_ACCESS_TOKEN}" \
    --data-urlencode "status=${text}" \
    --data-urlencode "visibility=public"); then
    jq -cn '{ok: false, error: "curl request failed (network/timeout)"}'
    return 0
  fi
  if echo "$response" | jq -e '.id != null' >/dev/null 2>&1; then
    jq -cn --arg id "$(echo "$response" | jq -r '.id')" --arg url "$(echo "$response" | jq -r '.url // empty')" '{ok: true, id: $id, url: $url}'
  else
    jq -cn --arg error "$response" '{ok: false, error: $error}'
  fi
}

# Fetches lyrics for a band/song from a free public lyrics API. Echoes the
# lyrics text and returns 0 on success; returns 1 (nothing echoed) if no
# lyrics are available (e.g. niche/local acts, or a title the API can't
# match) - the caller can't get a grounded quote for this song either way.
fetch_lyrics() {
  local band="$1" song="$2"
  local eband esong resp lyrics
  eband=$(jq -rn --arg s "$band" '$s|@uri')
  esong=$(jq -rn --arg s "$song" '$s|@uri')
  if ! resp=$(curl -sS --max-time 15 "https://api.lyrics.ovh/v1/${eband}/${esong}"); then
    return 1
  fi
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    # The API often fails to match titles with an apostrophe (e.g. "Don't
    # Stop Me Now") - retry once with it stripped before giving up.
    local song_noapo esong2
    song_noapo=$(echo "$song" | tr -d "'’‘")
    if [ "$song_noapo" != "$song" ]; then
      esong2=$(jq -rn --arg s "$song_noapo" '$s|@uri')
      resp=$(curl -sS --max-time 15 "https://api.lyrics.ovh/v1/${eband}/${esong2}") || true
    fi
  fi
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    return 1
  fi
  lyrics=$(echo "$resp" | jq -r '.lyrics // empty')
  [ -n "$lyrics" ] || return 1
  echo "$lyrics"
}

# Looks up which album a song first appeared on and when, via MusicBrainz
# (CC0 data, no API key needed, but it asks for a descriptive User-Agent and at
# most one request per second). Echoes "album<TAB>year" and returns 0; returns 1
# if nothing solid was found - the post then simply carries no album.
#
# It takes two requests: the recording search knows which release groups a song
# appears on, but not when those came out, so the candidates are looked up a
# second time by id. Only the band's own studio albums qualify - an official
# release of a release group typed "Album", with no secondary type and not
# credited to another artist, which is what rules out live records, best-ofs,
# bootlegs and samplers - and of those the oldest one wins, so the post names
# the album a song came from, not a reissue or a later record it turned up on.
MUSICBRAINZ_UA="song-quote-bot/1.0 ( https://github.com/schmidt-software/song-quote-bot )"
fetch_album_info() {
  local band="$1" song="$2"
  local query resp rg_ids info
  # A double quote inside the terms would break the search syntax - drop it.
  # status/primarytype narrow the search to songs that appear on an official
  # album at all, and -comment:live throws out the live recordings, of which a
  # touring band has hundreds: for "For Whom the Bell Tolls" they fill the
  # entire result page and bury the studio recording, which is the one whose
  # album the post is after. Filtering secondary types here instead would
  # backfire - it drops a studio recording just for also being on some
  # compilation - so that happens per release further down.
  query="artist:\"${band//\"/}\" AND recording:\"${song//\"/}\" AND status:official AND primarytype:album AND -comment:live"
  if ! resp=$(curl -sS --max-time 20 -G "https://musicbrainz.org/ws/2/recording" \
    --data-urlencode "query=$query" --data "fmt=json" --data "limit=50" \
    -H "User-Agent: ${MUSICBRAINZ_UA}"); then
    return 1
  fi
  # Only near-exact title matches count: lowering the score cutoff to 90 lets
  # other songs of the same band in, and an older one of those then wins the
  # "oldest album" pick below (e.g. "Come as You Are" landing on In Utero).
  rg_ids=$(echo "$resp" | jq -r --arg band "$band" '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
    [ .recordings[]? | select((.score // 0) >= 95)
      | select(((.disambiguation // "") | ascii_downcase | test("live")) | not)
      | .releases[]?
      | select((.status // "") == "Official")
      | select((."release-group"."primary-type" // "") == "Album")
      | select((((."release-group"."secondary-types") // []) | length) == 0)
      # A release credited to someone else is a sampler the song merely landed
      # on ("Various Artists") rather than a record of this band - that is how
      # a German hit compilation came out as the album of The Script. Plenty of
      # perfectly good releases carry no credit at all, so only a credit that
      # is there AND names somebody else disqualifies a release.
      | select((((.["artist-credit"] // []) | length) == 0)
               or ([.["artist-credit"][].name | norm] | index($band | norm) != null))
      | ."release-group".id ] | unique | .[:12] | join(" OR ")')
  [ -n "$rg_ids" ] || return 1
  # Stay within MusicBrainz's one-request-per-second rate limit.
  sleep 1
  if ! resp=$(curl -sS --max-time 20 -G "https://musicbrainz.org/ws/2/release-group" \
    --data-urlencode "query=rgid:(${rg_ids})" --data "fmt=json" --data "limit=25" \
    -H "User-Agent: ${MUSICBRAINZ_UA}"); then
    return 1
  fi
  info=$(echo "$resp" | jq -r '
    [ ."release-groups"[]? | select(((."first-release-date" // "") | length) >= 4)
      | {title: .title, date: ."first-release-date"} ]
    | sort_by(.date) | .[0] // empty | [.title, (.date[0:4])] | @tsv')
  [ -n "$info" ] || return 1
  echo "$info"
}

# Turns a Wikidata genre label into a hashtag: "hard rock" -> "#HardRock".
# Wikidata likes to spell a genre out as "... music" ("heavy metal music",
# "rock music"), which makes for a clumsy tag, so that trailing word goes as
# long as anything is left in front of it.
# A hashtag can't carry spaces, punctuation or accents, and one without a
# single letter isn't a hashtag on Mastodon - a label that doesn't survive all
# that simply gets no tag.
genre_hashtag() {
  local genre="$1" tag
  tag=$(printf '%s' "$genre" \
    | iconv -f utf8 -t ascii//TRANSLIT 2>/dev/null \
    | tr -cs 'a-zA-Z0-9' ' ' \
    | awk '{
        words = NF
        if (words > 1 && tolower($words) == "music") words--
        for (i = 1; i <= words; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)
      }')
  echo "$tag" | grep -q '[a-zA-Z]' || return 1
  echo "#${tag}"
}

# Checks a model-extracted quote against the real lyrics text it was
# supposedly extracted from - even when given the real text, a model can
# still paraphrase or drift from the exact wording. Echoes "verified" or
# "mismatch".
check_quote_in_lyrics() {
  local lyrics="$1" quote="$2"
  local norm_lyrics norm_quote
  # iconv//TRANSLIT strips accents the same way the lyrics source does
  # (e.g. "bück" -> "buck", not "bck") - without it, every umlaut/accent
  # mismatch would falsely look like a hallucination.
  norm_lyrics=$(echo "$lyrics" | iconv -f utf8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 \n' | tr -s ' \n' ' ')
  norm_quote=$(echo "$quote" | iconv -f utf8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 \n' | tr -s ' \n' ' ')
  if [ -n "$norm_quote" ] && echo "$norm_lyrics" | grep -qF "$norm_quote"; then
    echo "verified"
  else
    echo "mismatch"
  fi
}

DB_FILE="posted_quotes.json"
BANDS_FILE="bands.txt"
[ -f "$DB_FILE" ] || echo '[]' > "$DB_FILE"

SONG_SCHEMA='{"type":"object","properties":{"song":{"type":"string"}},"required":["song"],"additionalProperties":false}'
QUOTE_SCHEMA='{"type":"object","properties":{"quote":{"type":"string"}},"required":["quote"],"additionalProperties":false}'

# The band is picked here with `shuf`, not by the LLM: asked to "pick randomly",
# models reliably gravitate towards the most famous/typical choice (e.g. Rammstein
# - "Du hast") instead of sampling the list uniformly. To keep the rotation moving,
# the most recently used bands are excluded from the draw.
#
# Every line is "name<TAB>genre<TAB>country" as written by update_bands.sh.
# A list that still holds plain names (an older or hand-written one) keeps
# working - the post then just carries no genre and no country.
mapfile -t ALL_BANDS < "$BANDS_FILE"
TOTAL_BANDS=${#ALL_BANDS[@]}
EXCLUDE_COUNT=$(( TOTAL_BANDS > 4 ? 3 : (TOTAL_BANDS > 1 ? TOTAL_BANDS - 1 : 0) ))
mapfile -t RECENT_BANDS < <(jq -r '[.[].band] | reverse | .[]' "$DB_FILE" | awk '!seen[$0]++' | head -n "$EXCLUDE_COUNT")

CANDIDATE_BANDS=()
for b in "${ALL_BANDS[@]}"; do
  skip=0
  for r in "${RECENT_BANDS[@]:-}"; do
    # The database only stores the name, so that's what's compared here.
    [ "${b%%$'\t'*}" = "$r" ] && { skip=1; break; }
  done
  [ "$skip" -eq 0 ] && CANDIDATE_BANDS+=("$b")
done
[ ${#CANDIDATE_BANDS[@]} -eq 0 ] && CANDIDATE_BANDS=("${ALL_BANDS[@]}")

# How many recently posted quotes the prompt is told about. The database itself
# is kept complete - but feeding ALL of it to the model grows by one entry per
# run and eventually overflows the context window. The duplicate check further
# down still runs against the COMPLETE database, so nothing is forgotten; this
# list is only a hint that steers the model away from the most recent repeats.
#
# It is deliberately short, because the list cuts both ways: shown a pile of
# ready-made quotes, the model sometimes hands one straight back instead of
# reading the lyrics - the same quote for band after band, every attempt
# rejected as a duplicate until the run gives up with nothing posted. The
# longer the list, the more likely that is, and the little extra variety a
# longer one buys is not worth a failed run.
PROMPT_QUOTE_HISTORY=10

MAX_ATTEMPTS=10
success=0

# Everything below only reports failures, so without this the script sits there
# mute until something goes wrong - and the very first thing it does is the one
# step that can take a minute and a half (a cold model, see OLLAMA_KEEP_ALIVE).
# Run by hand, that is indistinguishable from a hang, so announce each attempt
# BEFORE making the call that might stall on it.
START_NOTE=""
[ "$DRY_RUN" = "1" ] && START_NOTE=" (DRY_RUN: es wird nichts gepostet und nichts gespeichert)"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Start - bis zu $MAX_ATTEMPTS Versuche${START_NOTE}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  BAND_LINE=$(printf '%s\n' "${CANDIDATE_BANDS[@]}" | shuf -n1)
  IFS=$'\t' read -r BAND BAND_GENRE BAND_COUNTRY <<< "$BAND_LINE"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Versuch $attempt/$MAX_ATTEMPTS: $BAND - frage Modell nach einem Song"
  EXISTING=$(jq -c --argjson n "$PROMPT_QUOTE_HISTORY" '[.[-$n:][] | .quote]' "$DB_FILE")
  # Same bias as with bands: left to itself, the model keeps reaching for the
  # band's single most famous song (e.g. always "Du hast" for Rammstein). Tell
  # it explicitly which songs of THIS band were already used.
  USED_SONGS=$(jq -c --arg band "$BAND" '[.[] | select((.band | ascii_downcase) == ($band | ascii_downcase)) | .song] | unique' "$DB_FILE")

  SONG_PROMPT="Die Band ist '${BAND}'. Wähle einen Song dieser Band aus, von dem du den Songtext zuverlässig und wortwörtlich kennst. Wähle nicht immer den bekanntesten Song - variiere bewusst."
  if [ "$USED_SONGS" != "[]" ]; then
    SONG_PROMPT="${SONG_PROMPT} Von dieser Band wurden bereits diese Songs verwendet, wähle einen ANDEREN: ${USED_SONGS}."
  fi
  SONG_PROMPT="${SONG_PROMPT} Antworte ausschließlich mit dem JSON-Objekt."

  SONG_REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$SONG_PROMPT" --argjson schema "$SONG_SCHEMA" --argjson ctx "$OLLAMA_NUM_CTX" --arg keep "$OLLAMA_KEEP_ALIVE" \
    '{model: $model, stream: false, think: false, keep_alive: $keep, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 0.7, num_ctx: $ctx}}')

  if ! SONG_RAW=$(curl -sS --max-time 90 "$OLLAMA_URL" -d "$SONG_REQUEST"); then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ollama-Aufruf fehlgeschlagen (Versuch $attempt, Songwahl)"
    continue
  fi

  SONG_RESULT=$(echo "$SONG_RAW" | jq -r '.message.content // empty')
  if [ -z "$SONG_RESULT" ] || ! echo "$SONG_RESULT" | jq -e . >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ungültige Ollama-Antwort (Versuch $attempt, Songwahl): $SONG_RAW"
    continue
  fi

  SONG=$(echo "$SONG_RESULT" | jq -r '.song')
  if [ -z "$SONG" ] || [ "$SONG" = "null" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Kein Song in Ollama-Antwort (Versuch $attempt, $BAND) - erneuter Versuch"
    continue
  fi

  SONG_REPEAT=$(jq --arg band "$BAND" --arg song "$SONG" \
    '[.[] | select((.band | ascii_downcase) == ($band | ascii_downcase) and (.song | ascii_downcase) == ($song | ascii_downcase))] | length' "$DB_FILE")

  if [ "$SONG_REPEAT" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Song bereits verwendet (Versuch $attempt, $BAND): $SONG - erneuter Versuch"
    continue
  fi

  # Fetch the real lyrics BEFORE asking for a quote, so the model extracts
  # a line from an actual source instead of recalling one from memory - this
  # is what actually prevents hallucination, rather than just detecting it
  # after the fact.
  if ! LYRICS=$(fetch_lyrics "$BAND" "$SONG"); then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Keine Songtext-Quelle verfügbar, kein Zitat möglich (Versuch $attempt, $BAND - $SONG) - erneuter Versuch"
    continue
  fi

  QUOTE_PROMPT="Hier ist der Songtext von '${SONG}' der Band '${BAND}':

${LYRICS}

Wähle daraus ein kurzes, einprägsames Zitat aus (maximal 1-2 aufeinanderfolgende Zeilen, KEINE ganze Strophe). Wichtig: Das Zitat MUSS wortwörtlich und exakt so im obigen Songtext vorkommen - kopiere es unverändert, erfinde oder verändere nichts. Das Zitat darf NICHT (auch nicht sinngemäß oder fast identisch) in dieser Liste bereits veröffentlichter Zitate enthalten sein: ${EXISTING}. Antworte ausschließlich mit dem JSON-Objekt."

  QUOTE_REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$QUOTE_PROMPT" --argjson schema "$QUOTE_SCHEMA" --argjson ctx "$OLLAMA_NUM_CTX" --arg keep "$OLLAMA_KEEP_ALIVE" \
    '{model: $model, stream: false, think: false, keep_alive: $keep, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 0.7, num_ctx: $ctx}}')

  if ! QUOTE_RAW=$(curl -sS --max-time 90 "$OLLAMA_URL" -d "$QUOTE_REQUEST"); then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ollama-Aufruf fehlgeschlagen (Versuch $attempt, Zitatwahl)"
    continue
  fi

  QUOTE_RESULT=$(echo "$QUOTE_RAW" | jq -r '.message.content // empty')
  if [ -z "$QUOTE_RESULT" ] || ! echo "$QUOTE_RESULT" | jq -e . >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ungültige Ollama-Antwort (Versuch $attempt, Zitatwahl): $QUOTE_RAW"
    continue
  fi

  QUOTE=$(echo "$QUOTE_RESULT" | jq -r '.quote')
  if [ -z "$QUOTE" ] || [ "$QUOTE" = "null" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Kein Zitat in Ollama-Antwort (Versuch $attempt, $BAND - $SONG) - erneuter Versuch"
    continue
  fi

  DUP=$(jq --arg q "$QUOTE" '[.[] | select((.quote | ascii_downcase) == ($q | ascii_downcase))] | length' "$DB_FILE")

  if [ "$DUP" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Duplikat erkannt (Versuch $attempt, $BAND): $QUOTE - erneuter Versuch"
    continue
  fi

  VERIFY_STATUS=$(check_quote_in_lyrics "$LYRICS" "$QUOTE")
  if [ "$VERIFY_STATUS" = "mismatch" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Zitat weicht vom echten Songtext ab, vermutlich verändert (Versuch $attempt, $BAND - $SONG): $QUOTE - erneuter Versuch"
    continue
  fi

  # Only now, for a quote that is actually going out, is the album looked up -
  # a discarded attempt shouldn't cost MusicBrainz a request.
  ALBUM=""
  ALBUM_YEAR=""
  if ALBUM_INFO=$(fetch_album_info "$BAND" "$SONG"); then
    IFS=$'\t' read -r ALBUM ALBUM_YEAR <<< "$ALBUM_INFO"
  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Kein Album gefunden ($BAND - $SONG) - Post ohne Albumangabe"
  fi

  # Everything beyond quote, band and song is optional, so the post is assembled
  # here instead of inline: a lookup that came up empty must not leave a stray
  # separator or a blank line in the middle of the toot.
  META_LINE=""
  if [ -n "$ALBUM" ]; then
    META_LINE="💿 ${ALBUM} (${ALBUM_YEAR})"
  fi
  if [ -n "${BAND_COUNTRY:-}" ]; then
    [ -n "$META_LINE" ] && META_LINE="${META_LINE} · "
    META_LINE="${META_LINE}🌍 ${BAND_COUNTRY}"
  fi

  HASHTAGS="#songquote #songcite"
  if [ -n "${BAND_GENRE:-}" ] && GENRE_TAG=$(genre_hashtag "$BAND_GENRE"); then
    HASHTAGS="${HASHTAGS} ${GENRE_TAG}"
  fi

  POST_TEXT="🎶 ${QUOTE} 🎤
(${BAND} · ${SONG}) 🎸"
  if [ -n "$META_LINE" ]; then
    POST_TEXT="${POST_TEXT}
${META_LINE}"
  fi
  POST_TEXT="${POST_TEXT}

${HASHTAGS}"

  # A dry run stops here: everything that could have gone wrong upstream has
  # been exercised by now, and what is left - publishing and recording it - is
  # exactly what a dry run must not do.
  if [ "$DRY_RUN" = "1" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DRY_RUN ($VERIFY_STATUS): nicht gepostet, nichts gespeichert - der Post wäre:"
    printf '%s\n' "$POST_TEXT" | sed 's/^/  | /'
    success=1
    break
  fi

  # Post to every configured target independently - one target being down
  # shouldn't block the others, but every result (success or failure) is
  # recorded so it's visible which platforms actually received the post.
  PLATFORM_ENTRIES="[]"
  any_ok=0
  for t in "${TARGET_LIST[@]}"; do
    case "$t" in
      mastodon) RESULT_JSON=$(post_to_mastodon "$POST_TEXT") ;;
    esac
    PLATFORM_ENTRIES=$(jq -c --arg k "$t" --argjson v "$RESULT_JSON" '. + [{key: $k, value: $v}]' <<< "$PLATFORM_ENTRIES")
    if echo "$RESULT_JSON" | jq -e '.ok == true' >/dev/null 2>&1; then
      any_ok=1
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Gepostet ($VERIFY_STATUS): \"$QUOTE\" ($BAND, $SONG${ALBUM:+, $ALBUM $ALBUM_YEAR}) - $(echo "$RESULT_JSON" | jq -r '.id')"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Post fehlgeschlagen (Versuch $attempt): $(echo "$RESULT_JSON" | jq -r '.error')"
    fi
  done

  if [ "$any_ok" -eq 1 ]; then
    PLATFORMS_JSON=$(jq -c 'from_entries' <<< "$PLATFORM_ENTRIES")
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # The extra fields record what the post actually showed; each is an empty
    # string when that lookup found nothing.
    jq --arg band "$BAND" --arg song "$SONG" --arg quote "$QUOTE" --argjson platforms "$PLATFORMS_JSON" --arg ts "$NOW" --arg verify "$VERIFY_STATUS" \
      --arg album "$ALBUM" --arg album_year "$ALBUM_YEAR" --arg genre "${BAND_GENRE:-}" --arg country "${BAND_COUNTRY:-}" \
      '. += [{"band":$band,"song":$song,"quote":$quote,"album":$album,"album_year":$album_year,"genre":$genre,"country":$country,"platforms":$platforms,"lyrics_check":$verify,"posted_at":$ts}]' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
    success=1
    break
  fi
done

if [ "$success" -ne 1 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FEHLER: Kein neues Zitat gefunden/gepostet nach $MAX_ATTEMPTS Versuchen." >&2
  exit 1
fi
