# `world-assets-gpt-image-2/` — the set the estate serves today

`CF_WORLD_ASSETS` in both `compose/mainnet.env` and `compose/testnet.env` points here, so this is
what `tessera-web` mounts read-only at `/usr/share/nginx/html/world-assets` and what every sprite
request resolves under.

**Nothing but this README is in git.** The 392 PNGs and `SET.json` are materialised on the host and
weigh 151 MB; the sibling directory `world-assets/` holds the FLUX 2 Pro set the same way. A fresh
host has to make them:

```sh
./scripts/provision-siblings.sh --all        # clones micro-tessera-assets as ../tessera-assets
cd ../tessera-assets
python3 materialise.py --provider gpt-image-2 --into ../deploy/compose/estate/world-assets-gpt-image-2
```

`materialise.py` refuses an incomplete set, so a directory it wrote is the full set or nothing.

## Why a second directory rather than overwriting the first

`world-assets/README.md` declares the FLUX bytes permanent, and it is right to: a promotion in
`micro-tessera-assets` is reversible by design (`promote.py --provider flux-2-pro`, one command, no
flag) and a deploy that destroyed the outgoing set would make the estate half of that switch
one-way. One variable selects which materialisation is served, both remain on disk, and switching
back is an edit to `CF_WORLD_ASSETS` and a deploy.

## Which set this is

`micro-tessera-assets` promoted `gpt-image-2` on 2026-08-16 (micro-tessera-assets#1). Its
`COMPARISON.md` is the argument, and the short version is that the coherence rows decided it —
27 assets below the accent floor against 46, accent hue error 6.4° against 9.8°, lightness spread
0.103 against 0.125 — while the legibility rows went the other way, 25 marks under 50% at 16px
against 40. That trade is defensible for a world drawn at tile scale and it is not a landslide;
the document says so in those words.
