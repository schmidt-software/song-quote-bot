#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Local, untracked config (see .env.example) - holds your Ollama endpoint etc.
[ -f ".env" ] && source ".env"

: "${OLLAMA_URL:?Set OLLAMA_URL (e.g. in .env) to your Ollama server, e.g. http://localhost:11434/api/chat}"
: "${OLLAMA_MODEL:?Set OLLAMA_MODEL (e.g. in .env) to the model to use, e.g. llama3.1:8b}"
: "${POST_NAME:=songcites}"

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
  PROMPT="${PROMPT} Das Zitat darf NICHT (auch nicht sinngemäß oder fast identisch) in dieser Liste bereits veröffentlichter Zitate enthalten sein: ${EXISTING}. Antworte ausschließlich mit dem JSON-Objekt."

  REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$PROMPT" --argjson schema "$SCHEMA" \
    '{model: $model, stream: false, think: false, messages: [{role: "user", content: $content}], format: $schema, options: {temperature: 1.1}}')

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
  RESPONSE=$(curl -sS -G 'https://gettogether.dev/post' --data-urlencode "name=${POST_NAME}" --data-urlencode "text=${TEXT}")

  if echo "$RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
    ID=$(echo "$RESPONSE" | jq -r '.id')
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg band "$BAND" --arg song "$SONG" --arg quote "$QUOTE" --arg id "$ID" --arg ts "$NOW" \
      '. += [{"band":$band,"song":$song,"quote":$quote,"id":$id,"posted_at":$ts}]' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Gepostet: \"$QUOTE\" ($BAND, $SONG) - ID $ID"
    success=1
    break
  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Post fehlgeschlagen (Versuch $attempt): $RESPONSE"
  fi
done

if [ "$success" -ne 1 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FEHLER: Kein neues Zitat gefunden/gepostet nach $MAX_ATTEMPTS Versuchen." >&2
  exit 1
fi
