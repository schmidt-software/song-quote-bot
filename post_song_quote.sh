#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Local, untracked config (see .env.example) - holds your Ollama endpoint etc.
[ -f ".env" ] && source ".env"

: "${OLLAMA_URL:?Set OLLAMA_URL (e.g. in .env) to your Ollama server, e.g. http://localhost:11434/api/chat}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL (e.g. in .env) to the model to use, e.g. llama3.1:8b}"
: "${POST_NAME:=songcites}"
: "${POST_TARGETS:=gettogether}"

# Validate every configured target up front, before doing any (costly) LLM work.
IFS=',' read -ra TARGET_LIST <<< "$POST_TARGETS"
for t in "${TARGET_LIST[@]}"; do
  case "$t" in
    gettogether) : ;;
    mastodon)
      : "${MASTODON_URL:?Set MASTODON_URL (e.g. in .env) to your Mastodon instance, e.g. https://mastodon.social}"
      : "${MASTODON_ACCESS_TOKEN:?Set MASTODON_ACCESS_TOKEN (e.g. in .env) - create one under Settings > Development > New Application with the write:statuses scope}"
      ;;
    *)
      echo "Unbekanntes POST_TARGET: '$t' (unterstützt: gettogether, mastodon)" >&2
      exit 1
      ;;
  esac
done

post_to_gettogether() {
  local text="$1" response
  if ! response=$(curl -sS --max-time 30 -G 'https://gettogether.dev/post' --data-urlencode "name=${POST_NAME}" --data-urlencode "text=${text}"); then
    jq -cn '{ok: false, error: "curl request failed (network/timeout)"}'
    return 0
  fi
  if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    jq -cn --arg id "$(echo "$response" | jq -r '.id')" '{ok: true, id: $id}'
  else
    jq -cn --arg error "$response" '{ok: false, error: $error}'
  fi
}

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

DB_FILE="posted_quotes.json"
BANDS_FILE="bands.txt"
[ -f "$DB_FILE" ] || echo '[]' > "$DB_FILE"

SCHEMA='{"type":"object","properties":{"song":{"type":"string"},"quote":{"type":"string"}},"required":["song","quote"],"additionalProperties":false}'

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

MAX_ATTEMPTS=5
success=0

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  BAND=$(printf '%s\n' "${CANDIDATE_BANDS[@]}" | shuf -n1)
  EXISTING=$(jq -c '[.[] | .quote]' "$DB_FILE")
  # Same bias as with bands: left to itself, the model keeps reaching for the
  # band's single most famous song (e.g. always "Du hast" for Rammstein). Tell
  # it explicitly which songs of THIS band were already used.
  USED_SONGS=$(jq -c --arg band "$BAND" '[.[] | select((.band | ascii_downcase) == ($band | ascii_downcase)) | .song] | unique' "$DB_FILE")

  PROMPT="Die Band ist '${BAND}'. Wähle einen Song dieser Band und ein kurzes, einprägsames Zitat (maximal 1-2 Zeilen, KEINE ganze Strophe) aus dem Songtext. Wähle nicht immer den bekanntesten Song - variiere bewusst."
  if [ "$USED_SONGS" != "[]" ]; then
    PROMPT="${PROMPT} Von dieser Band wurden bereits diese Songs verwendet, wähle einen ANDEREN: ${USED_SONGS}."
  fi
  PROMPT="${PROMPT} Das Zitat darf NICHT (auch nicht sinngemäß oder fast identisch) in dieser Liste bereits veröffentlichter Zitate enthalten sein: ${EXISTING}. Wichtig: Verwende ausschließlich eine Zeile, die wirklich und wortwörtlich im echten Songtext vorkommt. Erfinde NIEMALS eine Zeile. Wenn du dir bei einem Song nicht sicher bist, wähle einen anderen Song derselben Band, bei dem du dir des Wortlauts sicher bist. Antworte ausschließlich mit dem JSON-Objekt."

  REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$PROMPT" --argjson schema "$SCHEMA" \
    '{model: $model, stream: false, think: false, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 0.7}}')

  if ! RAW=$(curl -sS --max-time 90 "$OLLAMA_URL" -d "$REQUEST"); then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ollama-Aufruf fehlgeschlagen (Versuch $attempt)"
    continue
  fi

  RESULT=$(echo "$RAW" | jq -r '.message.content // empty')
  if [ -z "$RESULT" ] || ! echo "$RESULT" | jq -e . >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ungültige Ollama-Antwort (Versuch $attempt): $RAW"
    continue
  fi

  SONG=$(echo "$RESULT" | jq -r '.song')
  QUOTE=$(echo "$RESULT" | jq -r '.quote')

  SONG_REPEAT=$(jq --arg band "$BAND" --arg song "$SONG" \
    '[.[] | select((.band | ascii_downcase) == ($band | ascii_downcase) and (.song | ascii_downcase) == ($song | ascii_downcase))] | length' "$DB_FILE")

  if [ "$SONG_REPEAT" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Song bereits verwendet (Versuch $attempt, $BAND): $SONG - erneuter Versuch"
    continue
  fi

  DUP=$(jq --arg q "$QUOTE" '[.[] | select((.quote | ascii_downcase) == ($q | ascii_downcase))] | length' "$DB_FILE")

  if [ "$DUP" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Duplikat erkannt (Versuch $attempt, $BAND): $QUOTE - erneuter Versuch"
    continue
  fi

  TEXT="${QUOTE} (${BAND}, ${SONG})"

  # Post to every configured target independently - one target being down
  # shouldn't block the others, but every result (success or failure) is
  # recorded so it's visible which platforms actually received the post.
  PLATFORM_ENTRIES="[]"
  any_ok=0
  for t in "${TARGET_LIST[@]}"; do
    case "$t" in
      gettogether) RESULT_JSON=$(post_to_gettogether "$TEXT") ;;
      mastodon) RESULT_JSON=$(post_to_mastodon "🎶 ${QUOTE} 🎤
(${BAND} · ${SONG}) 🎸

#songquote #songcite") ;;
    esac
    PLATFORM_ENTRIES=$(jq -c --arg k "$t" --argjson v "$RESULT_JSON" '. + [{key: $k, value: $v}]' <<< "$PLATFORM_ENTRIES")
    if echo "$RESULT_JSON" | jq -e '.ok == true' >/dev/null 2>&1; then
      any_ok=1
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Gepostet: \"$QUOTE\" ($BAND, $SONG) - $(echo "$RESULT_JSON" | jq -r '.id')"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$t] Post fehlgeschlagen (Versuch $attempt): $(echo "$RESULT_JSON" | jq -r '.error')"
    fi
  done

  if [ "$any_ok" -eq 1 ]; then
    PLATFORMS_JSON=$(jq -c 'from_entries' <<< "$PLATFORM_ENTRIES")
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg band "$BAND" --arg song "$SONG" --arg quote "$QUOTE" --argjson platforms "$PLATFORMS_JSON" --arg ts "$NOW" \
      '. += [{"band":$band,"song":$song,"quote":$quote,"platforms":$platforms,"posted_at":$ts}]' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
    success=1
    break
  fi
done

if [ "$success" -ne 1 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FEHLER: Kein neues Zitat gefunden/gepostet nach $MAX_ATTEMPTS Versuchen." >&2
  exit 1
fi
