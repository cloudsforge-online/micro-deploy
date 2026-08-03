# `/world-assets/` — the materialisation target, empty on purpose

This directory is mounted read-only into `tessera-web` at
`/usr/share/nginx/html/world-assets`, which is the path
`tessera-web/src/lib/hosts.ts:118` resolves every sprite under and
`tessera-web/nginx.conf:73` serves with `try_files $uri =404`.

**It is empty, and empty is the correct state today.**

`micro-tessera-assets` has no `materialise.py`. The generation session is still
running, and the on-disk layout the client resolves against — content-addressed
bytes under a path that is identical in every provider's manifest, so the client
encodes no provider — does not exist yet to be pointed at. Until it does, every
sprite request 404s, the client reports the missing sprite **by name** and
substitutes nothing, and that is the behaviour `micro-tessera-web` designed for
and `scripts/estate-verify.sh` asserts.

## Why this is not pointed at `../../tessera-assets/assets/`

Because those bytes are the FLUX generation output, not the materialised world.
Mounting them would put *some* files under the path and convert an honest "there
is no materialised art in this environment" into "the art is mounted and every
sprite 404s" — the same class of error as a zero wearing a status code, and
harder to diagnose because the mount would look done.

There is a second, blunter reason: a docker bind mount whose host path does not
exist is **created** by the daemon. Defaulting to `../../tessera-assets/…` would
have written an empty directory into a repository this one does not own.

## The day `materialise.py` lands

Nothing in this repository changes. One variable moves:

```sh
CF_WORLD_ASSETS=../../tessera-assets/materialised ./scripts/estate-up.sh
```

The path is relative to `compose/`, which is where `docker-compose.estate.yml`
lives and therefore what docker resolves a relative bind mount against.

## What the verifier asserts about this today

That `/world-assets/<a file that is not there>` answers **404 and does not
carry the app shell**. Both halves matter and they fail in opposite directions:
a `try_files $uri /index.html` fallback would answer 200 with HTML, which a
browser tries to decode as a PNG and reports as a corrupt image naming the wrong
file; a bare nginx error page would be a 404 the client cannot distinguish from
a network fault. The check is what stops the mount, once it is real, from
silently regressing to either.
