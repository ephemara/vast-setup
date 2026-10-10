# packs — one model pipeline per file. Install/remove as a unit.

A pack is a self-contained install unit: every file one pipeline needs, with
its own download link. No cross-pack sharing logic, no 1000-link scavenger
hunt. The app (Part 2 sync) and `pack.sh` both speak this format.

## Layout

- `models/packages/<id>.pack.json` — one pipeline each (`klein-4b-core`,
  `wan-i2v-14b-core`, ...). Add a new model = add one file, never touch code.
- `models/manifest.json` — flat inventory scan of the laptop (kept for
  single-file `fetch.sh` + size truth). Packs carry the URLs; manifest is just
  the phonebook.

## Schema (`*.pack.json`)

```json
{
  "id": "klein-4b-core",
  "label": "Klein 4B core (image)",
  "kind": "klein",
  "version": 1,
  "description": "what this pipeline is",
  "files": [
    { "dir": "diffusion_models", "file": "model.gguf",
      "bytes": 2181382848, "url": "https://...", "auth": "none" }
    // "base": "comfy" escapes models/ for ComfyUI-root files, e.g.
    // { "base": "comfy", "dir": "custom_nodes/ComfyUI-WanVideoWrapper",
    //   "file": "nodes_utility.py", ... } -> <COMFY_DIR>/custom_nodes/...
  ]
}
```

- `kind` matches the app's workflow kind (`klein`, `wan`, ...). Same kind =
  same Comfy graph everywhere, local or cloud. New family = new kind + one
  builder fn in the app, works on all targets at once.
- `bytes` is the source of truth for verify (exact size match, no hashes in
  v1 — GGUF publishers rarely publish them; sizes catch truncated downloads).
- `auth`: `none` | `hf` | `civitai`.
  - `hf`: needs `HF_TOKEN` env (gated repos). Sent as
    `Authorization: Bearer <token>`.
  - `civitai`: needs `CIVITAI_TOKEN` env. Sent as
    `Authorization: Bearer <token>` (Civitai also accepts `?token=`; header
    is cleaner and keeps URLs shareable). Public Civitai files work with
    `auth: none` + a plain `https://civitai.com/api/download/models/<id>`
    URL — but keep the token set anyway, rate limits are kinder with it.
  - Empty `url` = "fill me in". `pack.sh` refuses to guess hosts and tells
    you exactly which file is missing a link.

## CLI

```bash
./models/pack.sh list                 # all packs + sizes + present/missing
./models/pack.sh info klein-4b-core   # per-file status
./models/pack.sh install klein-4b-core        # pull missing files only
./models/pack.sh verify klein-4b-core         # size-check, no downloads
./models/pack.sh remove klein-4b-core --yes  # delete exactly these files
```

Removal deletes ONLY the files listed in the pack. Shared files (a VAE two
packs reference) get listed per pack but `remove` warns before deleting a
file another installed pack still references. Nothing else on disk is
touched — no `rm -rf`, ever.

## Civitai — does it pose a problem?

No, with two footnotes:

1. **Auth.** Public files download fine anonymously, but automation should
   send a token (free API key from Civitai settings → `CIVITAI_TOKEN` env).
   Without it you hit stricter rate limits and gated files 403. Our
   `pack.sh`/`fetch.sh` send the header automatically when `auth: civitai`.
2. **URL shape.** Civitai links are API endpoints, not files:
   `https://civitai.com/api/download/models/<versionId>` (add
   `?type=Model&format=SafeTensor` only if the version has multiple files).
   Paste the version-level link, not the pretty web page URL. Redirects are
   followed (`curl -L`), resumable (`curl -C -`).
3. **License/ToS.** Civitai hosts community LoRAs with per-model licenses.
   Redistribution rights vary — but we never redistribute, we only store a
   *link* + pull at bake time. Same posture as HF. Fine.

## Making a new pack

1. Copy the smallest existing pack, change `id`/`label`/`kind`.
2. List every file the pipeline needs (diffusion, encoder, vae, vision,
   loras). Sizes from `manifest.json` or `stat -c%s`.
3. Fill `url` + `auth` per file. A core pack must be ONE-SHOT SYNCABLE:
   every file has a URL (`pack.sh json` reports `syncable`; the app's Models
   tab shows no-link packs as unsyncable and hides them from generate tabs).
   Never pad core with unlinked files — extra LoRAs ride separate packs.
   `install` refuses blank URLs and names the exact file missing a link.
4. `pack.sh verify <id>` on the laptop, commit, push. Box pulls it with
   `pack.sh install <id>`.
