#!/bin/bash
# fetch.sh — pull one model by name from models/manifest.json.
# Usage: ./models/fetch.sh <file> [--url URL] [--auth none|hf|civitai]
# URL resolution: explicit --url > manifest url > abort (never guess hosts).
# Auth: HF_TOKEN / CIVITAI_TOKEN env sent as Bearer header when --auth set
# (or when the URL host implies it). Packs call this per file; pack.sh is
# the unit you normally want (install/verify/remove a whole pipeline).
set -euo pipefail
cd "$(dirname "$0")"

FILE="${1:-}"; URL=""; TIER=""; AUTH="auto"
while [[ $# -gt 0 ]]; do case "$1" in
  --url) URL="$2"; shift 2;;
  --tier) TIER="$2"; shift 2;;
  --auth) AUTH="$2"; shift 2;;
  *) shift;;
esac; done
[[ -z "$FILE" ]] && { echo "usage: fetch.sh <file> [--url URL]"; exit 1; }

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
row=$(python3 -c "
import json
m = json.load(open('manifest.json'))
for o in m:
    if o['file'] == '$FILE':
        print(o['dir'] + '|' + str(o['bytes']) + '|' + o.get('url',''))
        break
")
[[ -z "$row" ]] && { echo "not in manifest: $FILE"; exit 1; }
DIR="${row%%|*}"; rest="${row#*|}"; SIZE="${rest%%|*}"; MURL="${rest#*|}"
[[ -n "$URL" ]] || URL="$MURL"
[[ -n "$URL" ]] || { echo "no URL for $FILE (pass --url or fill manifest)"; exit 1; }

dest="$COMFY_DIR/models/$DIR/$FILE"
if [[ -f "$dest" && "$(stat -c%s "$dest")" == "$SIZE" ]]; then
  echo "present: $FILE ($(numfmt --to=iec "$SIZE"))"
  exit 0
fi
mkdir -p "$(dirname "$dest")"
echo "fetching $FILE -> $DIR/ ($(numfmt --to=iec "$SIZE"))"
# auth: explicit --auth wins, else sniff the host (hf.co / civitai.com)
if [[ "$AUTH" == "auto" ]]; then
  case "$URL" in
    *huggingface.co*) AUTH="hf";;
    *civitai.com*) AUTH="civitai";;
    *) AUTH="none";;
  esac
fi
AUTH_ARGS=()
if [[ "$AUTH" == "hf" && -n "${HF_TOKEN:-}" ]]; then AUTH_ARGS=(-H "Authorization: Bearer $HF_TOKEN"); fi
if [[ "$AUTH" == "civitai" && -n "${CIVITAI_TOKEN:-}" ]]; then AUTH_ARGS=(-H "Authorization: Bearer $CIVITAI_TOKEN"); fi
curl -sL -C - --retry 5 --retry-delay 3 "${AUTH_ARGS[@]}" -o "$dest" "$URL"
[[ "$(stat -c%s "$dest")" == "$SIZE" ]] && echo "ok: $FILE" || { echo "SIZE MISMATCH for $FILE"; exit 1; }
