#!/bin/bash
# ============================================================================
# vast-setup bake — one idempotent script that turns a bare CUDA box into a
# mobile-comfy ComfyUI worker. Safe to re-run (every step checks first).
# Env in: TAILSCALE_AUTHKEY (required), BOX_HOSTNAME, HF_TOKEN, TORCH_CUDA.
# Fresh provisioning is a BANISHED concept here: you run this ONCE per
# snapshot, then only start/stop. Never per boot, never per gen.
# ============================================================================
set -euo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
COMFY_REV="a7169322"   # pinned = the exact build the laptop runs. Bump deliberately.
HERE="$(cd "$(dirname "$0")" && pwd)"
TORCH_CUDA="${TORCH_CUDA:-cu124}"   # cu124 = driver 550+, everywhere. cu130 needs R580+.

log() { echo "[bake] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 0. GPU
if ! have nvidia-smi; then log "FATAL: no nvidia-smi — not a GPU box"; exit 1; fi
# NOTE: `noindex` is NOT universal (some builds reject it) — use noheader and
# parse defensively. (A 580-driver box proved this the hard way: exit 2, zero
# output, found via bash -x.)
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | sed 's/^[^A-Za-z]*//')"
VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | grep -o '[0-9][0-9]*' | tail -n1)"
SM_RAW="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | grep -o '[0-9]*\.[0-9]*' | head -n1)"
SM="$(echo "$SM_RAW" | tr -d .)"
[[ -n "$GPU" && -n "$VRAM_MB" && -n "$SM" ]] || { log "FATAL: could not parse nvidia-smi output (gpu='$GPU' vram='$VRAM_MB' sm='$SM_RAW')"; exit 1; }
log "GPU=$GPU VRAM=${VRAM_MB}MB sm=$SM"
[[ "$SM" -ge 75 ]] || { log "FATAL: sm < 75 unsupported"; exit 1; }
if [[ "$SM" -lt 80 ]]; then log "note: pre-Ampere — sage-attention stays OFF (hard rule)"; fi

# ------------------------------------------------------------ 1. system deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl python3 python3-venv ffmpeg 2>&1 | tail -n1 || true
log "system deps ok"
# tailscale (best-effort here; section 6 joins). Needs its own apt repo —
# stock debian sources don't carry it, so the naive `apt install tailscale`
# silently fails and the bake dies later at `tailscale up`. Not anymore.
if ! have tailscale; then
  # Prefer upstream install.sh (handles ubuntu/debian trees + signed-by
  # keyring correctly). Manual fallback writes its own signed-by line — the
  # plain `<codename>.list` from pkgs omits signed-by and apt rejects it
  # with NO_PUBKEY even when the keyring file exists. Seen live on noble.
  curl -fsSL https://tailscale.com/install.sh -o /tmp/ts-install.sh 2>/dev/null \
    && sh /tmp/ts-install.sh 2>&1 | tail -n2 || {
    DISTRO_T="$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo ubuntu)"
    CODENAME="$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release 2>/dev/null || echo noble)"
    curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_T}/${CODENAME}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${DISTRO_T} ${CODENAME} main" \
      > /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq 2>&1 | tail -n1 || true
  }
  apt-get install -y -qq tailscale 2>&1 | tail -n1 || log "warn: tailscale install failed (section 6 will report)"
fi
have tailscale && log "tailscale bin ok" || log "warn: no tailscale binary — join will be skipped with a warning"

# --------------------------------- 2. python + torch (template-aware)
# Vast ComfyUI templates ship torch + cuda already. Never reinstall a working
# stack — detect first, only build the venv path on a truly bare box.
PY=""
for cand in "/venv/main/bin/python" "$COMFY_DIR/.venv/bin/python" "/venv/bin/python" "/opt/venv/bin/python"; do
  [[ -x "$cand" ]] && PY="$cand" && break
done
if [[ -z "$PY" ]] && python3 -c "import torch" 2>/dev/null; then PY="$(command -v python3)"; fi
if [[ -z "$PY" ]]; then
  log "no working torch python found (bare box) — creating venv + torch ($TORCH_CUDA)…"
  mkdir -p "$COMFY_DIR"
  python3 -m venv "$COMFY_DIR/.venv"
  PY="$COMFY_DIR/.venv/bin/python"
  "$PY" -m pip install -q --upgrade pip
  "$PY" -m pip install -q torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$TORCH_CUDA"
else
  log "using python: $PY"
fi
log "torch $("$PY" -c 'import torch; print(torch.__version__)' 2>/dev/null || echo MISSING)"
"$PY" -c "import torch" 2>/dev/null || { log "FATAL: torch still missing after setup"; exit 1; }

# ------------------------------------------------ 3. ComfyUI (template-aware)
# Template path (main.py exists): verify, don't reinstall. Bare path: clone.
if [[ -f "$COMFY_DIR/main.py" ]]; then
  log "comfy already installed (template) — verifying, not reinstalling"
  if [[ -d "$COMFY_DIR/.git" ]]; then
    CUR_REV="$(git -C "$COMFY_DIR" rev-parse --short HEAD)"
    log "comfy @ $CUR_REV (pinned $COMFY_REV)"
    if [[ "${FORCE_COMFY_REV:-0}" == "1" && "$CUR_REV" != "$COMFY_REV" ]]; then
      log "FORCE_COMFY_REV=1 — checking out $COMFY_REV"
      git -C "$COMFY_DIR" fetch -q origin
      git -C "$COMFY_DIR" checkout -q "$COMFY_REV"
      CUR_REV="$(git -C "$COMFY_DIR" rev-parse --short HEAD)"
    fi
    # DRIFT GUARD (2026-10-07 incident): template images self-update core across
    # reboots (ai-dock AUTO_UPDATE). A newer core than pinned breaks pinned
    # nodes (GGUF vs core-0.39 `input_act`). Loud warn, never silent — operator
    # then re-pins deliberately or forces the checkout. Warn-only (not fatal)
    # so non-GGUF boxes never block on a core they don't care about.
    if [[ "$CUR_REV" != "$COMFY_REV" ]] && grep -q "^ComfyUI-GGUF " "$HERE/nodes/nodes.lock"; then
      log "WARN: template core $CUR_REV != pinned $COMFY_REV with GGUF locked — gens may fail (input_act class)."
      log "WARN: fix with FORCE_COMFY_REV=1 (downgrade core to pinned) or re-pin both deliberately."
      log "WARN: also set AUTO_UPDATE=false at instance creation so the image stops moving core."
    fi
  else
    log "comfy install has no .git (template snapshot) — staying on it"
  fi
  # ensure deps (cheap no-op when already satisfied)
  "$PY" -m pip install -q -r "$COMFY_DIR/requirements.txt" 2>/dev/null \
    || log "warn: requirements ensure partial — continuing"
else
  log "no comfy found (bare box) — cloning @ $COMFY_REV"
  git clone -q https://github.com/Comfy-Org/ComfyUI "$COMFY_DIR"
  git -C "$COMFY_DIR" fetch -q origin
  git -C "$COMFY_DIR" checkout -q "$COMFY_REV"
  "$PY" -m pip install -q -r "$COMFY_DIR/requirements.txt"
fi
log "comfy ok: $COMFY_DIR/main.py"

# ---------------------------------------------------------- 4. custom nodes
NODES="$COMFY_DIR/custom_nodes"
mkdir -p "$NODES"
while read -r dir repo rev req; do
  [[ "$dir" =~ ^#.*$ || -z "$dir" ]] && continue
  if [[ ! -d "$NODES/$dir/.git" && ! -f "$NODES/$dir/__init__.py" ]]; then
    log "cloning $dir"
    git clone -q "$repo" "$NODES/$dir"
  fi
  if [[ -n "${rev:-}" && -d "$NODES/$dir/.git" ]]; then
    git -C "$NODES/$dir" fetch -q origin
    git -C "$NODES/$dir" checkout -q "$rev" 2>/dev/null || log "warn: $dir rev $rev missing upstream, staying"
  fi
  if [[ -n "${req:-}" && -f "$NODES/$dir/$req" ]]; then
    "$PY" -m pip install -q -r "$NODES/$dir/$req" || log "warn: $dir requirements partial"
  fi
done < "$HERE/nodes/nodes.lock"
"$PY" -m pip install -q gguf  # ComfyUI-GGUF has no requirements.txt; needs this
log "nodes ok: $(ls "$NODES" | tr '\n' ' ')"

# ------------------------------------------------------- 5. model skeletons
for d in diffusion_models text_encoders vae clip_vision loras input output user; do
  mkdir -p "$COMFY_DIR/models/$d" 2>/dev/null || mkdir -p "$COMFY_DIR/$d"
done
log "model dirs ready (core pull: ./models/fetch.sh or app Part-2 sync)"

# -------------------------------------------------------------- 6. tailscale
# Best-effort join: tailnet-first is the design, but a box without tailscale
# still proves nodes+comfy (SSH-proxy fallback). Never die here — warn loud.
if ! have tailscale; then
  log "warn: TAILSCALE SKIPPED — no binary (see section 1). Box reachable via Vast SSH proxy only."
elif ! tailscale status >/dev/null 2>&1; then
  [[ -n "${TAILSCALE_AUTHKEY:-}" ]] || log "warn: TAILSCALE_AUTHKEY not set — skipping join (set it + re-run bake to join)"
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    pgrep -x tailscaled >/dev/null 2>&1 || { tailscaled >/var/log/tailscaled.log 2>&1 & sleep 3; }
    tailscale up --auth-key="$TAILSCALE_AUTHKEY" --hostname="${BOX_HOSTNAME:-mc-gpu-01}" --accept-dns=false 2>&1 | tail -n3 \
      || log "warn: tailscale up failed (container may lack /dev/net/tun — proxy fallback applies)"
  fi
fi
log "tailscale: $(tailscale ip -4 2>/dev/null | head -n1 || echo NOT-JOINED)"

# --------------------------------------- 7. ComfyUI up (supervisor-aware)
# Vast base-image derivatives run comfyui as a SUPERVISOR service (internal
# :18188, flags in $COMFYUI_ARGS) — never nohup a second copy beside it.
# Bare boxes get the run.sh fallback on :8188.
# NOTE: flags.env sets COMFY_PORT=8188, so the supervisor branch must FORCE
# 18188 (not :-) — sourcing flags first poisons the default and the bake
# probes the wrong port, bounces a healthy service, then FATALs. Seen live.
if supervisorctl status comfyui >/dev/null 2>&1; then
  COMFY_PORT=18188
  log "supervisor manages comfyui — leaving the service alone (flags: \$COMFYUI_ARGS)"
  supervisorctl status comfyui || true
else
  # shellcheck disable=SC1091
  set -a; . "$HERE/comfy/flags.env"; set +a
  COMFY_PORT="${COMFY_PORT:-8188}"
  # run.sh uses the same python bake resolved ($PY), not a hardcoded venv —
  # template boxes often have no .venv at all.
  cat > "$COMFY_DIR/run.sh" <<EOF
#!/bin/bash
cd "$COMFY_DIR" || exit 1
PY_BIN="$PY"
if [[ "\$PY_BIN" == *".venv"* && -f "\$(dirname "\$PY_BIN")/activate" ]]; then
  source "\$(dirname "\$PY_BIN")/activate"
fi
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=8 MKL_NUM_THREADS=8
nohup "\$PY_BIN" main.py $COMFY_ARGS > comfy.log 2>&1 &
echo \$! > comfy.pid
echo "comfy pid \$(cat comfy.pid), log $COMFY_DIR/comfy.log"
EOF
  chmod +x "$COMFY_DIR/run.sh"
fi
if ! curl -sf -m 3 "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null; then
  if supervisorctl status comfyui >/dev/null 2>&1; then
    log "comfyui service down — restarting via supervisor…"
    supervisorctl restart comfyui
  else
    log "starting ComfyUI…"
    bash "$COMFY_DIR/run.sh"
  fi
  for i in $(seq 1 24); do
    sleep 5
    curl -sf -m 3 "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null && break
    [[ "$i" == 24 ]] && { log "FATAL: comfy never answered on :$COMFY_PORT"; exit 1; }
  done
fi
log "comfy answering on :$COMFY_PORT"

# ------------------------------------------------------------------ summary
echo "================ BAKE COMPLETE ================"
echo "gpu:      $GPU (${VRAM_MB}MB)"
echo "comfy:    $(git -C "$COMFY_DIR" rev-parse --short HEAD 2>/dev/null || echo "template-snapshot") + $(ls "$NODES" | wc -l) node packs"
echo "torch:    $("$PY" -c 'import torch; print(torch.__version__)')"
echo "tailnet:  $(tailscale ip -4 2>/dev/null | head -n1)"
echo "disk:     $(df -h /workspace | awk 'NR==2{print $3"/"$2}')"
echo "models:   packs next -> ./models/pack.sh install klein-4b-core (then wan-i2v-14b-core)"
echo "SNAPSHOT THIS DISK NOW. Then only start/stop, forever."
