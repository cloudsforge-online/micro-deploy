# `/world-assets/` — the materialisation target

This directory is mounted read-only into `tessera-web` at
`/usr/share/nginx/html/world-assets`, which is the path
`tessera-web/src/lib/hosts.ts` resolves every sprite under and
`tessera-web/nginx.conf:73` serves with `try_files $uri =404`.

**It held one README until 2026-08-05, and that was a live defect for as long as
it lasted.** The lines below used to say "it is empty, and empty is the correct
state today", on the grounds that `micro-tessera-assets` had no
`materialise.py`. It has had one for some time. Nothing re-read this file when
that changed, so the correct state and the actual state diverged silently: a
complete, validated, 392-asset FLUX 2 Pro set sat in `micro-tessera-assets`
while every sprite request on **both** networks answered 404, the client
resolved the mount to `absent`, and Tessera rendered an empty world to everyone
who opened it. No check went red, because until now no check drove the two
together.

## What is here now

The `flux-2-pro` set, materialised whole: `SET.json` plus 392 PNGs.

```sh
python3 materialise.py --provider flux-2-pro --into <this directory>   # in micro-tessera-assets
```

**THIS IS NO LONGER THE SET THE ESTATE SERVES, and that is a variable rather than a change here.**
On 2026-08-16 `micro-tessera-assets` promoted `gpt-image-2` over FLUX 2 Pro as its shipped set
(micro-tessera-assets#1), and `CF_WORLD_ASSETS` in both `compose/mainnet.env` and
`compose/testnet.env` now names `./estate/world-assets-gpt-image-2`. These bytes stay exactly where
they are, for the reason the next line has always given: the promotion is reversible in one command
in the asset repository, and a deploy that overwrote the outgoing set would make the estate half of
that switch one-way. Point the variable back and FLUX is served again with nothing else touched.

`materialise.py` refuses an incomplete set, so a directory it wrote is either
the full reference set or nothing. `SET.json` is the receipt beside the bytes:
it maps every asset IDENTITY (`tiles/ashfield-ground-a`) to the PATH it was
written at (`tiles/ashfield-ground-a-256x128.png`), which is the whole reason
`tessera-web/src/lib/asset-set.ts` exists — the client asks by identity and
never spells a filename, so the delivered size in the name cannot drift into a
second naming convention nobody can see.

**The bytes here are permanent.** They are the FLUX 2 Pro generation output. Do
not delete, overwrite or regenerate them; a challenger provider materialises to
its own directory and `CF_WORLD_ASSETS` points at whichever one is being served.

## Why this is not pointed at `../../tessera-assets/assets/`

Because those bytes are the FLUX generation output as generated, not the
materialised world. The manifest's `path` and the client's `identity` are
different strings on every one of the 392 entries, so mounting the raw
directory would put *some* files under the path and convert an honest "there is
no materialised art in this environment" into "the art is mounted and every
sprite 404s" — the same class of error as a zero wearing a status code, and
harder to diagnose because the mount would look done.

There is a second, blunter reason: a docker bind mount whose host path does not
exist is **created** by the daemon. Defaulting to `../../tessera-assets/…` would
have written an empty directory into a repository this one does not own.

## Pointing at a different set

One variable moves; nothing in this repository changes:

```sh
CF_WORLD_ASSETS=../../tessera-assets/materialised ./scripts/estate-up.sh
```

The path is relative to `compose/`, which is where `docker-compose.estate.yml`
lives and therefore what docker resolves a relative bind mount against.

## What now asserts this, and why the old check was not enough

`scripts/estate-verify.sh` asserts that `/world-assets/<a file that is not
there>` answers **404 and does not carry the app shell**. Both halves matter and
they fail in opposite directions: a `try_files $uri /index.html` fallback would
answer 200 with HTML, which a browser tries to decode as a PNG and reports as a
corrupt image naming the wrong file; a bare nginx error page would be a 404 the
client cannot distinguish from a network fault.

That check was correct and it was satisfied throughout the outage, because it
only ever asked what happens to a file that is **absent by construction**. It
never asked whether a file that is supposed to be **present** is.

So `beacon`'s browser tier now declares this mount as art Tessera cannot work
without (`beacon/src/browser/smoke.ts`, `SmokeSurface.imagery`) and, in a real
Chromium against the real gateway, fetches `SET.json`, parses it, and asks the
browser to decode a real ground tile. An empty mount fails that in two places
and names both. Tessera has no `<img>` tags at all — it draws into a canvas from
`ImageBitmap`s and `SpriteCache.fetchOne` swallows its own 404s by design — so
no assertion about markup could have caught this, and none should be relied on
to catch it next time.
