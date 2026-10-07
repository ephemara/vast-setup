#!/bin/bash
# push.sh — thin local wrapper. Sends THIS repo + env to a box over SSH and
# runs the bake there. Secrets come from YOUR machine (env or ~/.config),
# never from the repo. The box pulls GBs itself; the laptop sends bytes of text.
#
# Usage: TAILSCALE_AUTHKEY="$(cat ~/.config/tailscale/authkey)" ./bin/push.sh root@<host> [ssh-port]
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${1:?usage: push.sh root@<host> [ssh-port]}"
PORT="${2:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

[[ -n "${TAILSCALE_AUTHKEY:-}" ]] || { echo "TAILSCALE_AUTHKEY not set (see .env.example)"; exit 1; }

echo "[push] syncing repo to $HOST (no secrets included — .gitignore enforced)"
ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o BatchMode=yes "root@${HOST#root@}" "mkdir -p /opt/vast-setup"
# scp via git archive so ignored files can never hitch a ride
git archive HEAD | ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o BatchMode=yes "root@${HOST#root@}" "tar -x -C /opt/vast-setup"

echo "[push] running bake (env only, over the wire)"
ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o BatchMode=yes "root@${HOST#root@}" \
  "TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY' BOX_HOSTNAME='${BOX_HOSTNAME:-mc-gpu-01}' HF_TOKEN='${HF_TOKEN:-}' CIVITAI_TOKEN='${CIVITAI_TOKEN:-}' COMFY_DIR='${COMFY_DIR:-/workspace/ComfyUI}' FORCE_COMFY_REV='${FORCE_COMFY_REV:-0}' TORCH_CUDA='${TORCH_CUDA:-cu124}' bash /opt/vast-setup/bake.sh"
echo "[push] done — verify with: ssh $HOST 'curl -s localhost:8188/system_stats'"
