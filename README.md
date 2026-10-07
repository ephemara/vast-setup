# vast-setup — one bake script for mobile-comfy cloud workers. Public.

Golden-snapshot religion: you run `bake.sh` **once per snapshot**, then only
start/stop the box. Never per boot, never per gen. Fresh provisioning is banned.

## Layout

- `bake.sh` — the all-in-one. Idempotent: re-running only fills gaps.
- `nodes/nodes.lock` — custom nodes (repo + pinned rev, matching the laptop).
- `models/manifest.json` — every model file (`dir/file/bytes/tier/url`).
  `tier: core` (~29GB: Klein Q4 + Wan 14B Q4 + clips + vaes + key LoRAs) fits a
  54GB box. `extended` = everything else, pulled on demand.
- `models/fetch.sh` — pull one file by name (never guesses hosts; needs a URL).
- `comfy/flags.env` — launch flags. Universal profile; arch guards live in bake.
- `workflows/` — prompt packs (Comfy graphs arrive with workflow kinds later).
- `bin/push.sh` — thin local wrapper: ships this repo (git archive, so ignored
  files can't hitch a ride) + env over SSH, runs the bake. Secrets come from
  YOUR machine, never this repo.

## Bake a box

```bash
TAILSCALE_AUTHKEY="$(cat ~/.config/tailscale/authkey)" \
BOX_HOSTNAME=mc-gpu-01 \
./bin/push.sh root@<box-ip> [ssh-port]
```

Then pull core models (`models/fetch.sh <file> --url <hf-link>` or the app's
Part-2 sync), verify `:8188/system_stats`, **snapshot the disk**, stop the box.

## Secrets

None live here. `.env.example` documents what's needed. If a key ever touches
this tree: `git rm` it, rotate it, assume it's burned.
