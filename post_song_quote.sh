#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# cron appends this run's output to the log file (see crontab). Once we're
# done writing to it, trim it back down to the last MAX_LOG_ENTRIES lines so
# the file can't grow forever - oldest entries drop off first.
LOG_FILE="post_song_quote.log"
MAX_LOG_ENTRIES=20
trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  local tmp
  tmp=$(mktemp "${LOG_FILE}.XXXXXX")
  tail -n "$MAX_LOG_ENTRIES" "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}
trap trim_log EXIT

# Local, untracked config (see .env.example) - holds your Ollama endpoint etc.
[ -f ".env" ] && source ".env"

: "${OLLAMA_URL:?Set OLLAMA_URL (e.g. in .env) to your Ollama server, e.g. http://localhost:11434/api/chat}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL (e.g. in .env) to the model to use, e.g. llama3.1:8b}"
: "${POST_TARGETS:=mastodon}"

# Validate every configured target up front, before doing any (costly) LLM work.
IFS=',' read -ra TARGET_LIST <<< "$POST_TARGETS"
for t in "${TARGET_LIST[@]}"; do
  case "$t" in
    mastodon)
      : "${MASTODON_URL:?Set MASTODON_URL (e.g. in .env) to your Mastodon instance, e.g. https://mastodon.social}"
      : "${MASTODON_ACCESS_TOKEN:?Set MASTODON_ACCESS_TOKEN (e.g. in .env) - create one under Settings > Development > New Application with the write:statuses scope}"
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
mapfile -t ALL_BANDS < "$BANDS_FILE"
TOTAL_BANDS=${#ALL_BANDS[@]}
EXCLUDE_COUNT=$(( TOTAL_BANDS > 4 ? 3 : (TOTAL_BANDS > 1 ? TOTAL_BANDS - 1 : 0) ))
mapfile -t RECENT_BANDS < <(jq -r '[.[].band] | reverse | .[]' "$DB_FILE" | awk '!seen[$0]++' | head -n "$EXCLUDE_COUNT")

CANDIDATE_BANDS=()
for b in "${ALL_BANDS[@]}"; do
  skip=0
  for r in "${RECENT_BANDS[@]:-}"; do
    [ "$b" = "$r" ] && { skip=1; break; }
  done
  [ "$skip" -eq 0 ] && CANDIDATE_BANDS+=("$b")
done
[ ${#CANDIDATE_BANDS[@]} -eq 0 ] && CANDIDATE_BANDS=("${ALL_BANDS[@]}")

MAX_ATTEMPTS=10
success=0

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  BAND=$(printf '%s\n' "${CANDIDATE_BANDS[@]}" | shuf -n1)
  EXISTING=$(jq -c '[.[] | .quote]' "$DB_FILE")
  # Same bias as with bands: left to itself, the model keeps reaching for the
  # band's single most famous song (e.g. always "Du hast" for Rammstein). Tell
  # it explicitly which songs of THIS band were already used.
  USED_SONGS=$(jq -c --arg band "$BAND" '[.[] | select((.band | ascii_downcase) == ($band | ascii_downcase)) | .song] | unique' "$DB_FILE")

  SONG_PROMPT="Die Band ist '${BAND}'. Wähle einen Song dieser Band aus, von dem du den Songtext zuverlässig und wortwörtlich kennst. Wähle nicht immer den bekanntesten Song - variiere bewusst."
  if [ "$USED_SONGS" != "[]" ]; then
    SONG_PROMPT="${SONG_PROMPT} Von dieser Band wurden bereits diese Songs verwendet, wähle einen ANDEREN: ${USED_SONGS}."
  fi
  SONG_PROMPT="${SONG_PROMPT} Antworte ausschließlich mit dem JSON-Objekt."

  SONG_REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$SONG_PROMPT" --argjson schema "$SONG_SCHEMA" \
    '{model: $model, stream: false, think: false, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 0.7}}')

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

  QUOTE_REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$QUOTE_PROMPT" --argjson schema "$QUOTE_SCHEMA" \
    '{model: $model, stream: false, think: false, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 0.7}}')

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

  # Post to every configured target independently - one target being down
  # shouldn't block the others, but every result (success or failure) is
  # recorded so it's visible which platforms actually received the post.
  PLATFORM_ENTRIES="[]"
  any_ok=0
  for t in "${TARGET_LIST[@]}"; do
    case "$t" in
      mastodon) RESULT_JSON=$(post_to_mastodon "🎶 ${QUOTE} 🎤
(${BAND} · ${SONG}) 🎸

#songquote #songcite") ;;
    esac
    PLATFORM_ENTRIES=$(jq -c --arg k "$t" --argjson v "$RESULT_JSON" '. + [{key: $k, value: $v}]' <<< "$PLATFORM_ENTRIES")
    if echo "$RESULT_JSON" | jq -e '.ok == true' >/dev/null 2>&1; then
      any_ok=1
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Gepostet ($VERIFY_STATUS): \"$QUOTE\" ($BAND, $SONG) - $(echo "$RESULT_JSON" | jq -r '.id')"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Post fehlgeschlagen (Versuch $attempt): $(echo "$RESULT_JSON" | jq -r '.error')"
    fi
  done

  if [ "$any_ok" -eq 1 ]; then
    PLATFORMS_JSON=$(jq -c 'from_entries' <<< "$PLATFORM_ENTRIES")
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg band "$BAND" --arg song "$SONG" --arg quote "$QUOTE" --argjson platforms "$PLATFORMS_JSON" --arg ts "$NOW" --arg verify "$VERIFY_STATUS" \
      '. += [{"band":$band,"song":$song,"quote":$quote,"platforms":$platforms,"lyrics_check":$verify,"posted_at":$ts}]' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
    success=1
    break
  fi
done

if [ "$success" -ne 1 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FEHLER: Kein neues Zitat gefunden/gepostet nach $MAX_ATTEMPTS Versuchen." >&2
  exit 1
fi
