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

SCHEMA='{"type":"object","properties":{"band":{"type":"string"},"song":{"type":"string"},"quote":{"type":"string"}},"required":["band","song","quote"],"additionalProperties":false}'

BANDS=$(paste -sd, "$BANDS_FILE")
LAST_BAND=$(jq -r 'if length > 0 then .[-1].band else "" end' "$DB_FILE")

MAX_ATTEMPTS=5
success=0

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  EXISTING=$(jq -c '[.[] | .quote]' "$DB_FILE")

  PROMPT="Wähle zufällig genau eine Band aus dieser Liste: ${BANDS}."
  if [ -n "$LAST_BAND" ]; then
    PROMPT="${PROMPT} Die zuletzt gewählte Band war '${LAST_BAND}' - wähle diesmal eine ANDERE Band."
  fi
  PROMPT="${PROMPT} Wähle dann zufällig einen Song dieser Band und ein kurzes, einprägsames Zitat (maximal 1-2 Zeilen, KEINE ganze Strophe) aus dem Songtext. Das Zitat darf NICHT (auch nicht sinngemäß oder fast identisch) in dieser Liste bereits veröffentlichter Zitate enthalten sein: ${EXISTING}. Antworte ausschließlich mit dem JSON-Objekt."

  REQUEST=$(jq -n --arg model "$OLLAMA_MODEL" --arg content "$PROMPT" --argjson schema "$SCHEMA" \
    '{model: $model, stream: false, think: false, messages: [{role: "user", content: $content}], format: $schema}')

  if ! RAW=$(curl -sS --max-time 90 "$OLLAMA_URL" -d "$REQUEST"); then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ollama-Aufruf fehlgeschlagen (Versuch $attempt)"
    continue
  fi

  RESULT=$(echo "$RAW" | jq -r '.message.content // empty')
  if [ -z "$RESULT" ] || ! echo "$RESULT" | jq -e . >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Ungültige Ollama-Antwort (Versuch $attempt): $RAW"
    continue
  fi

  BAND=$(echo "$RESULT" | jq -r '.band')
  SONG=$(echo "$RESULT" | jq -r '.song')
  QUOTE=$(echo "$RESULT" | jq -r '.quote')

  if [ -n "$LAST_BAND" ] && [ "$(echo "$BAND" | tr '[:upper:]' '[:lower:]')" = "$(echo "$LAST_BAND" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Gleiche Band wie zuletzt erkannt (Versuch $attempt): $BAND - erneuter Versuch"
    continue
  fi

  DUP=$(jq --arg q "$QUOTE" '[.[] | select((.quote | ascii_downcase) == ($q | ascii_downcase))] | length' "$DB_FILE")

  if [ "$DUP" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Duplikat erkannt (Versuch $attempt): $QUOTE - erneuter Versuch"
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
