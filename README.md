# vast-setup — one bake script for mobile-comfy cloud workers. Public.

Golden-snapshot religion: you run `bake.sh` **once per snapshot**, then only
start/stop the box. Never per boot, never per gen. Fresh provisioning is banned.

## Layout

- `bake.sh` — the all-in-one. Idempotent: re-running only fills gaps.
- `nodes/nodes.lock` — custom nodes (repo + pinned rev, matching the laptop).
- `models/packages/<id>.pack.json` — one pipeline per file (DiT + encoder +
  vae + loras + links). Install/remove as a unit: `pack.sh install klein-4b-core`
  (~9GB), `pack.sh install wan-i2v-14b-core` (~20GB). Both fit a 54GB box
  with room. New model = new pack file, never code. See `models/packages/README.md`.
- `models/pack.sh` — `list | info | install | verify | remove` a whole pack.
  Removal deletes exactly the pack's files (shared-file guard warns).
- `models/manifest.json` — flat inventory scan of the laptop (size truth for
  single-file pulls). Packs carry the URLs; manifest is the phonebook.
- `models/fetch.sh` — pull one file by name (never guesses hosts; needs a URL).
  Auth-aware: `HF_TOKEN` / `CIVITAI_TOKEN` sent as Bearer headers.
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

Template-first: bake assumes the Vast ComfyUI image (torch + cuda + ComfyUI
present) and only VERIFIES it — no second install. Bare boxes still work
(full venv + torch + clone fallback). Then install packs
(`pack.sh install klein-4b-core`, `pack.sh install wan-i2v-14b-core` — or
the app's Part-2 sync later), verify `:8188/system_stats`, **snapshot the
disk**, stop the box.

## Secrets

None live here. `.env.example` documents what's needed. If a key ever touches
this tree: `git rm` it, rotate it, assume it's burned.
