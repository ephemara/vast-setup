#!/bin/bash
# pack.sh — install / verify / remove a model PACK (one pipeline per file).
# Usage:
#   ./models/pack.sh list
#   ./models/pack.sh info <pack-id>
#   ./models/pack.sh install <pack-id> [--dry-run]
#   ./models/pack.sh verify <pack-id>
#   ./models/pack.sh remove <pack-id> --yes
#   ./models/pack.sh json [pack-id]   # machine-readable inventory (for the app)
# Env: COMFY_DIR (default /workspace/ComfyUI), HF_TOKEN (auth:hf),
#      CIVITAI_TOKEN (auth:civitai). Never guesses hosts: blank url = abort
#      with the exact file named.
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:-}"; PACK="${2:-}"; FLAG="${3:-}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
PKGS="packages"

have_pack() { [[ -f "$PKGS/$PACK.pack.json" ]] || { echo "unknown pack: $PACK (try: pack.sh list)"; exit 1; }; }
pack_label() { python3 -c "import json;print(json.load(open('$PKGS/$PACK.pack.json'))['label'])"; }
pack_bytes() { python3 -c "import json;print(sum(f['bytes'] for f in json.load(open('$PKGS/$PACK.pack.json'))['files']))"; }

# shared-file guard: is $dir/$file referenced by another pack?
referenced_elsewhere() {
  local dir="$1" file="$2"
  python3 - "$dir" "$file" "$PACK" <<'PY'
import json, glob, sys
d, f, me = sys.argv[1], sys.argv[2], sys.argv[3]
hits = [p for p in glob.glob('packages/*.pack.json')
        if json.load(open(p))['id'] != me
        and any(x['dir'] == d and x['file'] == f for x in json.load(open(p))['files'])]
print(' '.join(h.split('/')[-1][:-9] for h in hits))
PY
}

pack_dest() { # base dir file -> absolute dest (base=comfy escapes models/ for custom-node files)
  if [[ "${1:-models}" == "comfy" ]]; then printf '%s' "$COMFY_DIR/$2/$3"; else printf '%s' "$COMFY_DIR/models/$2/$3"; fi
}
file_status() { # base dir file bytes -> present|missing|partial PATH
  local base="$1" dir="$2" file="$3" bytes="$4" dest="$(pack_dest "$base" "$dir" "$file")"
  if [[ -f "$dest" ]]; then
    [[ "$(stat -c%s "$dest")" == "$bytes" ]] && echo "present $dest" || echo "partial $dest"
  else echo "missing $dest"; fi
}

dl_one() { # base dir file url auth bytes — idempotent + resume-safe.
  # present files are never re-downloaded; partials resume via curl -C -;
  # overfull locals (manual copy / upstream shrink) are wiped for a fresh pull.
  local base="$1" dir="$2" file="$3" url="$4" auth="$5" bytes="$6"
  local dest="$(pack_dest "$base" "$dir" "$file")"
  read -r st _ < <(file_status "$base" "$dir" "$file" "$bytes")
  if [[ "$st" == "present" ]]; then echo "present: $file"; return 0; fi
  [[ -n "$url" ]] || { echo "NO URL for $file — fill it in $PKGS/$PACK.pack.json"; return 1; }
  local auth_args=()
  if [[ "$auth" == "hf" && -n "${HF_TOKEN:-}" ]]; then auth_args=(-H "Authorization: Bearer $HF_TOKEN"); fi
  if [[ "$auth" == "civitai" && -n "${CIVITAI_TOKEN:-}" ]]; then auth_args=(-H "Authorization: Bearer $CIVITAI_TOKEN"); fi
  if [[ "$auth" != "none" ]]; then
    local tok_var="$(echo "$auth" | tr 'a-z' 'A-Z')_TOKEN"
    [[ -n "${!tok_var:-}" ]] || echo "warn: auth=$auth but \$$tok_var unset — trying anonymous"
  fi
  mkdir -p "$(dirname "$dest")"
  local have=0
  [[ -f "$dest" ]] && have="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [[ "$have" -gt "$bytes" ]]; then
    echo "OVERFULL $file (have $(numfmt --to=iec "$have"), want $(numfmt --to=iec "$bytes")) — stale manual copy or upstream shrank, wiping for a fresh pull"
    rm -f "$dest"
    have=0
  fi
  if [[ "$have" -gt 0 ]]; then
    echo "resuming $file ($have/$bytes, $(numfmt --to=iec "$have") of $(numfmt --to=iec "$bytes")) -> $dir/"
  else
    echo "fetching $file -> $dir/ ($(numfmt --to=iec "$bytes"))"
  fi
  # Silent curl + our own PROGRESS heartbeat (one compact line per 2s): the proc
  # tail stays small and parseable, and the app renders per-file % from it.
  # --fail keeps HTTP errors out of model files.
  curl -sS -fL -C - --retry 5 --retry-delay 3 "${auth_args[@]}" -o "$dest" "$url" &
  local cpid=$!
  while kill -0 $cpid 2>/dev/null; do
    sleep 2
    kill -0 $cpid 2>/dev/null || break
    local now="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    echo "PROGRESS $file $(( now * 100 / bytes ))% ($now/$bytes)"
  done
  if wait $cpid; then
    local got="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [[ "$got" == "$bytes" ]]; then echo "ok: $file"; return 0; fi
    echo "SIZE MISMATCH for $file (have $got, want $bytes)"
    if [[ "$got" -gt "$bytes" ]]; then
      echo "hint: local is BIGGER than the manifest — upstream file likely changed. 'pack.sh verify $PACK' shows all files; delete + retry pulls fresh."
    elif [[ "$got" -lt "$bytes" ]]; then
      echo "hint: local is SMALLER — download stopped early (spot kill / network cut). Just retry: resume continues where it left off."
    fi
    return 1
  else
    local code=$?
    echo "DOWNLOAD FAILED for $file (curl exit $code)"
    if [[ "$code" == "33" ]]; then
      echo "hint: server refused resume range — wiping partial and retry fresh on next run"
      rm -f "$dest"
    elif [[ "$code" == "22" ]]; then
      echo "hint: HTTP error (404/403?) — URL may be dead, check the pack json"
    fi
    return 1
  fi
}

case "$CMD" in
  list)
    for p in "$PKGS"/*.pack.json; do
      id=$(python3 -c "import json;print(json.load(open('$p'))['id'])")
      n=$(python3 -c "import json;print(len(json.load(open('$p'))['files']))")
      total=$(python3 -c "import json;print(sum(f['bytes'] for f in json.load(open('$p'))['files']))")
      present=$(python3 - "$p" <<'PY'
import json, os, sys
pack = json.load(open(sys.argv[1]))
base = os.environ.get('COMFY_DIR', '/workspace/ComfyUI')
ok = 0
for f in pack['files']:
    root = '' if f.get('base') == 'comfy' else 'models'
    dest = os.path.join(base, root, f['dir'], f['file'])
    if os.path.isfile(dest) and os.path.getsize(dest) == f['bytes']: ok += 1
print(f"{ok}/{len(pack['files'])}")
PY
)
      echo "$id — $present files, $(numfmt --to=iec "$total") total"
    done ;;
  info)
    [[ -n "$PACK" ]] || { echo "usage: pack.sh info <pack-id>"; exit 1; }
    have_pack
    echo "== $PACK — $(pack_label) ($(numfmt --to=iec "$(pack_bytes)"))"
    python3 - "$PKGS/$PACK.pack.json" "$COMFY_DIR" <<'PY'
import json, os, sys
pack = json.load(open(sys.argv[1])); base = sys.argv[2]
for f in pack['files']:
    root = '' if f.get('base') == 'comfy' else 'models'
    dest = os.path.join(base, root, f['dir'], f['file'])
    if os.path.isfile(dest):
        ok = os.path.getsize(dest) == f['bytes']
        print(('OK   ' if ok else 'PART ') + f"{f['dir']}/{f['file']}")
    else: print('MISS ' + f"{f['dir']}/{f['file']}" + ('' if f.get('url') else '  (no url yet)'))
PY
    ;;
  install)
    [[ -n "$PACK" ]] || { echo "usage: pack.sh install <pack-id>"; exit 1; }
    have_pack
    if [[ "$FLAG" == "--dry-run" ]]; then
      echo "would install $PACK — $(pack_label) ($(numfmt --to=iec "$(pack_bytes)"))"
      exec bash "$0" info "$PACK"
    fi
    # Single-flight per pack: a second SYNC press (or a double-click) must not
    # stack a duplicate multi-GB download. Second runner exits fast with a loud line.
    lockdir="/tmp/mc-pack-$PACK.lock"
    if ! mkdir "$lockdir" 2>/dev/null; then
      echo "SYNC ALREADY RUNNING for $PACK (lock $lockdir) — wait for it or 'rm -rf $lockdir' if stale"
      exit 2
    fi
    trap 'rm -rf "$lockdir"' EXIT
    fail=0
    while IFS='|' read -r base dir file bytes url auth; do
      dl_one "$base" "$dir" "$file" "$url" "$auth" "$bytes" || fail=1
    done < <(python3 -c "
import json
for f in json.load(open('$PKGS/$PACK.pack.json'))['files']:
    print(f.get('base','models')+'|'+f['dir']+'|'+f['file']+'|'+str(f['bytes'])+'|'+f.get('url','')+'|'+f.get('auth','none'))")
    [[ "$fail" == 0 ]] && echo "pack $PACK ready" || { echo "pack $PACK INCOMPLETE (see above)"; exit 1; } ;;
  verify)
    [[ -n "$PACK" ]] || { echo "usage: pack.sh verify <pack-id>"; exit 1; }
    have_pack
    exec bash "$0" info "$PACK" ;;
  json)
    # Machine inventory for the mobile-comfy app (attach flow + cloud picker).
    # One JSON object, no URLs (links never leave the box over this channel).
    if [[ -n "$PACK" ]]; then have_pack; GLOB="$PKGS/$PACK.pack.json"; else GLOB="$PKGS/*.pack.json"; fi
    python3 - "$COMFY_DIR" $GLOB <<'PY'
import json, os, sys, glob
base = sys.argv[1]
files = []
for g in sys.argv[2:]:
    for p in glob.glob(g):
        try: files.append(p)
        except Exception: pass
out = []
for p in sorted(set(files)):
    try: pack = json.load(open(p))
    except Exception: continue
    fs = []
    for f in pack.get('files', []):
        root = '' if f.get('base') == 'comfy' else 'models'
        dest = os.path.join(base, root, f['dir'], f['file'])
        try:
            present = os.path.isfile(dest) and os.path.getsize(dest) == f['bytes']
            partial = os.path.isfile(dest) and os.path.getsize(dest) != f['bytes']
        except OSError: present = False; partial = False
        fs.append({'dir': f['dir'], 'file': f['file'], 'bytes': f['bytes'],
                   'base': f.get('base', 'models'), 'present': present, 'partial': partial,
                   'hasUrl': bool(f.get('url'))})
    n_missing_url = sum(1 for f in fs if not f['present'] and not f['hasUrl'])
    out.append({'id': pack.get('id'), 'label': pack.get('label', ''), 'kind': pack.get('kind', ''),
                'description': pack.get('description', ''), 'files': fs,
                'present': sum(1 for f in fs if f['present']), 'total': len(fs),
                'syncable': n_missing_url == 0,
                'hasComfyFiles': any(f.get('base') == 'comfy' for f in pack.get('files', []))})
print(json.dumps({'ok': True, 'packs': out}))
PY
    ;;
  remove)
    [[ -n "$PACK" ]] || { echo "usage: pack.sh remove <pack-id> --yes"; exit 1; }
    have_pack
    [[ "$FLAG" == "--yes" ]] || { echo "refusing without --yes (deletes files). Run: pack.sh remove $PACK --yes"; exit 1; }
    while IFS='|' read -r base dir file bytes; do
      dest="$(pack_dest "$base" "$dir" "$file")"
      [[ -f "$dest" ]] || { echo "absent: $dir/$file"; continue; }
      others="$(referenced_elsewhere "$dir" "$file")"
      [[ -n "$others" ]] && echo "warn: $file also in pack(s): $others — still deleting (shared file)"
      rm -f "$dest" && echo "removed: $dir/$file"
    done < <(python3 -c "
import json
for f in json.load(open('$PKGS/$PACK.pack.json'))['files']:
    print(f.get('base','models')+'|'+f['dir']+'|'+f['file']+'|'+str(f['bytes']))")
    echo "pack $PACK removed" ;;
  *) echo "usage: pack.sh {list|info|install|verify|remove|json} [pack-id]"; exit 1 ;;
esac
