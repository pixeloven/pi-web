# syntax=docker/dockerfile:1
#
# Portable PI WEB container image (published as ghcr.io/pixeloven/pi-web).
#
# Builds upstream jmfederico/pi-web from an exact release tag, verified against
# its commit, and adds a small runtime entrypoint (pi-web-container) that turns
# environment variables into Pi configuration at start-up. See README.md.
#
# This is not the upstream docker/ setup: that one is a host-integrated local
# install (Docker socket, host mounts, hostexec). This image mounts nothing from
# the host and suits Docker Compose or Kubernetes.

# --- Pins -------------------------------------------------------------------
# On upgrade, move PI_WEB_VERSION and PI_WEB_COMMIT together. Pi core
# (@earendil-works/*) is pinned to the versions in that release's
# package-lock.json, so it always matches what upstream built and tested.
ARG PI_WEB_VERSION=1.202611.1
ARG PI_WEB_COMMIT=98316bd808a4f7e51c414750ec315e4454bc9db7
ARG PI_WEB_REPO=https://github.com/jmfederico/pi-web.git

ARG NODE_IMAGE=node:22.22.2-bookworm-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.1
ARG AST_GREP_VERSION=0.51.1

# Pi packages baked into the image, as exact `npm:<name>@<version>` sources.
# They are installed under /opt/pi-web and registered in Pi's settings at
# start-up, so they survive any volume mounted over the home directory.
# Set to an empty string for an image with no extra Pi packages.
ARG PI_PACKAGES="npm:@gotgenes/pi-permission-system@42.0.0 npm:pi-subagents@0.87.0 npm:pi-web-access@0.47.0"

FROM ${UV_IMAGE} AS uv

# --- Build: upstream source -> global install under /opt/pi-web/global -------
FROM ${NODE_IMAGE} AS build
ARG PI_WEB_VERSION
ARG PI_WEB_COMMIT
ARG PI_WEB_REPO
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# node-pty and tree-sitter build from source; the toolchain stays in this stage.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git python3 make g++ jq \
  && rm -rf /var/lib/apt/lists/*

COPY build/ /opt/pi-web-build/

WORKDIR /src
RUN git init --quiet . \
  && git remote add origin "${PI_WEB_REPO}" \
  && git fetch --depth 1 --quiet origin "refs/tags/v${PI_WEB_VERSION}" \
  && git checkout --quiet FETCH_HEAD \
  && actual="$(git rev-parse HEAD)" \
  && if [ -n "${PI_WEB_COMMIT}" ] && [ "${actual}" != "${PI_WEB_COMMIT}" ]; then \
       echo "v${PI_WEB_VERSION} resolved to ${actual}, expected ${PI_WEB_COMMIT}" >&2; exit 1; \
     fi \
  && test "$(jq -r .version package.json)" = "${PI_WEB_VERSION}"

# `npm pack` drops package-lock.json, so pin the packed manifest to the lockfile
# before installing it; otherwise direct dependencies and peers float at build
# time.
RUN npm ci --no-audit --no-fund \
  && npm run build \
  && node /opt/pi-web-build/pin-runtime-deps.mjs > /tmp/pinned.json \
  && npm pack --quiet --ignore-scripts --pack-destination /tmp \
  && mv /tmp/jmfederico-pi-web-*.tgz /tmp/pi-web.tgz

# Build args are declared where they are used, so changing one does not
# invalidate the PI WEB build above.
ARG AST_GREP_VERSION
RUN pi_version="$(jq -r '.peerDependencies["@earendil-works/pi-coding-agent"]' /tmp/pinned.json)" \
  && npm install --global --prefix /opt/pi-web/global --omit=dev --no-audit --no-fund \
       /tmp/pi-web.tgz \
       "@earendil-works/pi-coding-agent@${pi_version}" \
       "@ast-grep/cli@${AST_GREP_VERSION}" \
  && test "$(/opt/pi-web/global/bin/pi --version)" = "${pi_version}"

# Pi installs packages with peers omitted so they bind to the host Pi at load
# time; do the same here. Only exact npm versions are accepted.
ARG PI_PACKAGES
WORKDIR /opt/pi-web/pi-packages
RUN set -e; \
  specs=(); dirs=(); \
  for source in ${PI_PACKAGES}; do \
    if [[ ! "${source}" =~ ^npm:((@[a-z0-9._-]+/)?[a-z0-9._-]+)@([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?)$ ]]; then \
      echo "PI_PACKAGES entries must be exact npm:<name>@<version> sources: ${source}" >&2; exit 1; \
    fi; \
    specs+=("${source#npm:}"); \
    dirs+=("/opt/pi-web/pi-packages/node_modules/${BASH_REMATCH[1]}"); \
  done; \
  echo '{"private":true}' > package.json; \
  if [ "${#specs[@]}" -gt 0 ]; then \
    npm install --omit=dev --omit=peer --legacy-peer-deps --no-audit --no-fund "${specs[@]}"; \
  fi; \
  for dir in "${dirs[@]}"; do test -f "${dir}/package.json"; done; \
  printf '%s\n' "${dirs[@]}" | jq -R . | jq -s 'map(select(length > 0))' > /opt/pi-web/pi-packages/image-packages.json; \
  jq -n \
    --arg version "${PI_WEB_VERSION}" \
    --arg commit "$(git -C /src rev-parse HEAD)" \
    --slurpfile pinned /tmp/pinned.json \
    --slurpfile packages /opt/pi-web/pi-packages/image-packages.json \
    --arg sources "${PI_PACKAGES}" \
    '{piWeb: {version: $version, commit: $commit}, pi: {version: $pinned[0].peerDependencies["@earendil-works/pi-coding-agent"]}, piPackages: {sources: ($sources | split(" ") | map(select(length > 0))), paths: $packages[0]}}' \
    > /opt/pi-web/image.json

# Build gate: the baked permission policy must validate against the schema
# shipped by the pinned extension. An invalid policy is ignored by the
# extension, which would silently drop every deny rule.
COPY rootfs/opt/pi-web/defaults/permissions.json /tmp/permissions.json
RUN package=/opt/pi-web/pi-packages/node_modules/@gotgenes/pi-permission-system; \
  schema="${package}/schemas/permissions.schema.json"; \
  if [ -d "${package}" ]; then \
    test -f "${schema}" || { echo "missing permission schema: ${schema}" >&2; exit 1; }; \
    npx --yes ajv-cli@5.0.0 validate --spec=draft2020 --strict=false -s "${schema}" -d /tmp/permissions.json; \
  fi

# --- Runtime ------------------------------------------------------------------
FROM ${NODE_IMAGE}
ARG PI_WEB_VERSION
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="pi-web" \
      org.opencontainers.image.description="PI WEB (jmfederico/pi-web) packaged as a portable container image" \
      org.opencontainers.image.version="${PI_WEB_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# git: worktrees and repository work. tini: PID 1 and signal forwarding.
# The rest are common tools for coding-agent sessions.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git gnupg jq less openssh-client procps ripgrep tini \
       python3 python3-pip python3-venv \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Trust repositories cloned by any UID; let git use GH_TOKEN through gh when set.
RUN git config --system --add safe.directory '*' \
  && git config --system credential."https://github.com".helper '!gh auth git-credential'

COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=build /opt/pi-web /opt/pi-web
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/pi-web-container /usr/local/bin/pi-login \
  && chmod 0444 /opt/pi-web/defaults/*

ENV HOME=/home/node \
    PATH=/opt/pi-web/global/bin:${PATH} \
    PI_WEB_HOST=0.0.0.0 \
    PI_WEB_PORT=8504 \
    PI_WEB_DEFAULTS_CONFIG=/opt/pi-web/defaults/config.json \
    PI_WEB_PI_PACKAGE_DIR=/opt/pi-web/global/lib/node_modules/@earendil-works/pi-coding-agent \
    NPM_CONFIG_UPDATE_NOTIFIER=false

USER node
WORKDIR /home/node
RUN mkdir -p /home/node/.pi-web /home/node/.config/pi-web /home/node/projects \
  && mkdir -p -m 0700 /home/node/.pi /home/node/.pi/agent

EXPOSE 8504
ENTRYPOINT ["/usr/bin/tini", "--", "pi-web-container"]
CMD ["all"]
