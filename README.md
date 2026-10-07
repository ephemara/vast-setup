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

## Pin policy (read after the 2026-10-07 `input_act` outage)

Every rev in this repo is pinned: `COMFY_REV` in `bake.sh`, every line of
`nodes/nodes.lock`. Unpinned (=tip) is how a box breaks while nobody watches —
a template image self-updated ComfyUI core 0.37→0.39 across a reboot while the
GGUF node stayed put, and core started passing `input_act`, a kwarg the node
build rejects (`GGMLOps.Linear.forward_ggml_cast_weights` TypeError, every
GGUF gen red). Pinned-and-working beats latest-and-surprising.

Rules:

- **Bump revs deliberately, never by drift.** New rev = commit with the
  reason, proven by a gen on a box, not by a reboot surprise.
- **GGUF boxes: `FORCE_COMFY_REV=1`.** Template core moves on its own;
  forcing the checkout keeps core at the pinned rev the nodes were proven
  against. Until city96 supports core-0.39's `input_act`, core stays put.
- **Set `AUTO_UPDATE=false` at instance creation** (ai-dock template env).
  Otherwise the image re-updates core on every boot and the bake's drift
  guard will shout at you (triple-WARN when template core != pinned core
  with GGUF locked — heed it, don't scroll past it).

## Secrets

None live here. `.env.example` documents what's needed. If a key ever touches
this tree: `git rm` it, rotate it, assume it's burned.
