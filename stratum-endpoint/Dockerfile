# syntax=docker/dockerfile:1.7
#
# stratum-endpoint (micro-org#457). Single context — this service has no @cloudsforge/* sibling
# dependencies, which is deliberate: it must keep watching even while the rest of the estate is
# mid-deploy, and every dependency is a way for that to stop being true.
#
#   docker build -t stratum-endpoint deploy/stratum-endpoint

# The docker CLI and the compose plugin, taken from the image that owns them and pinned. Debian's
# `docker-compose-v2` is not in slim's repositories — building against it fails with apt exit 100,
# which is how this stage came to exist rather than an `apt-get install`.
FROM docker:27-cli AS dockercli

FROM node:22-slim AS runtime

COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose \
                      /usr/local/libexec/docker/cli-plugins/docker-compose

WORKDIR /app
COPY package.json tsconfig*.json ./
RUN npm install --no-save tsx typescript @types/node
COPY src ./src

ENV NODE_ENV=production
EXPOSE 4000

# Root, and only because the mounted docker socket is root-owned on this host. The process opens no
# port to the internet and holds no credential; its whole surface is /metrics and /livez.
CMD ["node", "--import", "tsx", "src/index.ts"]
