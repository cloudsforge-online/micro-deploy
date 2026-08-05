# syntax=docker/dockerfile:1.7
#
# The backup runner. Build context is `deploy/backup`, plus one named context for the unpublished
# sibling packages:
#
#   docker build -t backup-runner --build-context runtimepkgs=../../runtime deploy/backup
#
# The extra context is temporary, exactly as in admin-api's Dockerfile: once the @cloudsforge/*
# packages are published (AD-02) this becomes an ordinary single-context build. It is named
# `runtimepkgs` rather than `runtime` because a build context and a build stage share one namespace
# and the final stage below is called `runtime`.

# ----------------------------------------------------------------------------------- deps
FROM node:22-slim AS deps
RUN corepack enable && corepack prepare pnpm@11.9.0 --activate
WORKDIR /app

COPY --from=runtimepkgs package.json pnpm-workspace.yaml pnpm-lock.yaml /runtime/
COPY --from=runtimepkgs packages /runtime/packages

# The siblings' OWN dependencies first: `link:` uses the sibling as-is and does not manage its
# dependency tree, so `/runtime`'s node_modules must exist independently — both for `tsc` to resolve
# the sibling source it typechecks and for `node --import tsx` to load @cloudsforge/* at run time.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm-store,sharing=locked \
    pnpm --dir /runtime install --frozen-lockfile --config.store-dir=/pnpm-store

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN --mount=type=cache,id=pnpm-store,target=/pnpm-store,sharing=locked \
    pnpm install --frozen-lockfile --config.store-dir=/pnpm-store

# ----------------------------------------------------------------------------------- build
FROM deps AS build
COPY tsconfig.json tsconfig.base.json ./
COPY src ./src
RUN pnpm typecheck

# ----------------------------------------------------------------------------------- runtime
FROM node:22-slim AS runtime
WORKDIR /app

# ══════════════════════════════════════════════════════════════════════════════════════════════
# **THE POSTGRESQL CLIENT IS PINNED TO 17, FROM PGDG, AND THAT IS NOT A PREFERENCE.**
#
# The estate's server is `postgres:17-alpine`, reporting 17.10 (verified on the host). Debian
# bookworm's own `postgresql-client` is 15. The failure that pairing produces is the worst kind:
#
#   · a 15 `pg_restore` cannot read a 17 custom-format archive at all — loud, and survivable;
#   · a 15 `pg_dump` against a 17 server produces an archive that restores with OMISSIONS rather
#     than an error — silent, and the reason `src/index.ts` refuses to start on a major-version
#     mismatch rather than trusting this file to have been got right.
#
# `age` is here for the miner coinbase key. It encrypts to a PUBLIC recipient key held in
# BACKUP_AGE_RECIPIENT; the private identity never exists on this host, so a compromise of this
# image or this container yields ciphertext. See src/secrets.ts. There is deliberately no
# unencrypted fallback, which means a missing `age` binary is a failed artefact rather than a
# plaintext private key on the backup disk — the build must not "helpfully" make it optional.
#
# `tar` and `gzip` come with the base image and are used for the vault and asset archives.
# ══════════════════════════════════════════════════════════════════════════════════════════════
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg age; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-17; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/*; \
    pg_dump --version | grep -q ' 17\.' || { echo "pg_dump is not 17"; exit 1; }; \
    age --version

# No corepack, no pnpm, no build toolchain in the final image.
COPY --from=build /runtime /runtime
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/tsconfig.json /app/tsconfig.base.json ./
COPY --from=build /app/src ./src

# ══════════════════════════════════════════════════════════════════════════════════════════════
# **uid 1000, WHICH IS ALSO malf ON THE HOST AND custody's uid IN ITS VOLUME.**
#
# Three things depend on this being 1000 and not root:
#   · the custody vault is mode 0700 owned by 1000 (`compose/docker-compose.estate.yml`, custody's
#     init step). A root reader would work, but running as root to read a key vault is the wrong
#     default for the one container in the estate that holds ciphertext for every coin.
#   · the backup destination is created 0700 malf:malf, and malf is uid 1000.
#   · the miner coinbase key files are 0600 malf:malf.
#
# node:22-slim already ships `node` at uid 1000.
# ══════════════════════════════════════════════════════════════════════════════════════════════
USER node

# No secret is baked in and none may be. In particular there is NO env line for anything matching
# CUSTODY_MASTER_SECRET_V*: `src/keyring.ts` refuses to start if one is present in the environment
# at all, because this container writes the custody vault and the vault and the keyring must never
# share a medium (docs/custody-backup-restore.md §1.5). BACKUP_AGE_RECIPIENT is a PUBLIC key and is
# supplied by the deploy; it is safe in a compose file, which is the point of choosing age.
ENV NODE_ENV=production
EXPOSE 4130

# The health endpoints are for the orchestrator, not for the image.
CMD ["node", "--import", "tsx", "src/index.ts"]
