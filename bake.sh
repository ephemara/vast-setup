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
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noindex,nounits | head -n1)"
SM="$(nvidia-smi --query-gpu=compute_cap --format=csv,noindex,nounits | head -n1 | tr -d .)"
log "GPU=$GPU VRAM=${VRAM_MB}MB sm=$SM"
[[ "$SM" -ge 75 ]] || { log "FATAL: sm < 75 unsupported"; exit 1; }
if [[ "$SM" -lt 80 ]]; then log "note: pre-Ampere — sage-attention stays OFF (hard rule)"; fi

# ------------------------------------------------------------ 1. system deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl python3 python3-venv ffmpeg tailscale 2>/dev/null \
  || apt-get install -y -qq git curl python3 python3-venv ffmpeg
log "system deps ok"

# ------------------------------------------------------- 2. python + torch
if [[ ! -x "$COMFY_DIR/.venv/bin/python" ]]; then
  mkdir -p "$COMFY_DIR"
  python3 -m venv "$COMFY_DIR/.venv"
fi
PY="$COMFY_DIR/.venv/bin/python"
"$PY" -m pip install -q --upgrade pip
if ! "$PY" -c "import torch" 2>/dev/null; then
  log "installing torch ($TORCH_CUDA) — one time, ~2GB…"
  "$PY" -m pip install -q torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$TORCH_CUDA"
fi
log "torch $("$PY" -c 'import torch; print(torch.__version__)')"

# -------------------------------------------------------------- 3. ComfyUI
if [[ ! -f "$COMFY_DIR/main.py" ]]; then
  git clone -q https://github.com/Comfy-Org/ComfyUI "$COMFY_DIR"
fi
git -C "$COMFY_DIR" fetch -q origin
git -C "$COMFY_DIR" checkout -q "$COMFY_REV"
"$PY" -m pip install -q -r "$COMFY_DIR/requirements.txt"
log "comfyui @ $(git -C "$COMFY_DIR" rev-parse --short HEAD)"

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
if ! tailscale status >/dev/null 2>&1; then
  [[ -n "${TAILSCALE_AUTHKEY:-}" ]] || { log "FATAL: TAILSCALE_AUTHKEY not set"; exit 1; }
  tailscale up --auth-key="$TAILSCALE_AUTHKEY" --hostname="${BOX_HOSTNAME:-mc-gpu-01}" --accept-dns=false
fi
log "tailscale: $(tailscale ip -4 2>/dev/null | head -n1)"

# ------------------------------------------------------- 7. run script + up
# shellcheck disable=SC1091
set -a; . "$HERE/comfy/flags.env"; set +a
cat > "$COMFY_DIR/run.sh" <<EOF
#!/bin/bash
cd "$COMFY_DIR" || exit 1
source .venv/bin/activate
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export OMP_NUM_THREADS=8 MKL_NUM_THREADS=8
nohup python main.py $COMFY_ARGS > comfy.log 2>&1 &
echo \$! > comfy.pid
echo "comfy pid \$(cat comfy.pid), log $COMFY_DIR/comfy.log"
EOF
chmod +x "$COMFY_DIR/run.sh"
if ! curl -sf -m 3 "http://127.0.0.1:${COMFY_PORT:-8188}/system_stats" >/dev/null; then
  log "starting ComfyUI…"
  bash "$COMFY_DIR/run.sh"
  for i in $(seq 1 24); do
    sleep 5
    curl -sf -m 3 "http://127.0.0.1:${COMFY_PORT:-8188}/system_stats" >/dev/null && break
    [[ "$i" == 24 ]] && { log "FATAL: comfy never answered (see comfy.log)"; exit 1; }
  done
fi
log "comfy answering on :${COMFY_PORT:-8188}"

# ------------------------------------------------------------------ summary
echo "================ BAKE COMPLETE ================"
echo "gpu:      $GPU (${VRAM_MB}MB)"
echo "comfy:    $(git -C "$COMFY_DIR" rev-parse --short HEAD) + $(ls "$NODES" | wc -l) node packs"
echo "torch:    $("$PY" -c 'import torch; print(torch.__version__)')"
echo "tailnet:  $(tailscale ip -4 2>/dev/null | head -n1)"
echo "disk:     $(df -h /workspace | awk 'NR==2{print $3"/"$2}')"
echo "models:   core pull next -> cd $HERE && ./models/fetch.sh <file> --url <hf-link>"
echo "SNAPSHOT THIS DISK NOW. Then only start/stop, forever."
