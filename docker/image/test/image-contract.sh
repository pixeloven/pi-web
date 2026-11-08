#!/usr/bin/env bash
# Container-side scripts are single-quoted on purpose: they expand inside the image.
# shellcheck disable=SC2016
# Contract test for the portable PI WEB image.
#
#   docker/image/test/image-contract.sh <image>
#
# Needs only a Docker-compatible CLI (Docker, or Podman through DOCKER_HOST).
# Uses no network access beyond the local engine and no credentials: every
# key below is a dummy value, and the checks assert it is never written to disk.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <image>" >&2
  exit 2
fi

image=$1
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
dockerfile="$here/../Dockerfile"
suffix="${GITHUB_RUN_ID:-local}-$$"
volumes=()
containers=()

cleanup() {
  for c in "${containers[@]}"; do docker rm -f "$c" > /dev/null 2>&1 || true; done
  for v in "${volumes[@]}"; do docker volume rm -f "$v" > /dev/null 2>&1 || true; done
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# new_volume NAME: create a fresh home volume and store its name in $home.
# Not called through $(...), so the cleanup list is updated in this shell.
new_volume() {
  home="pi-web-contract-$1-$suffix"
  docker volume create "$home" > /dev/null
  volumes+=("$home")
}

# run VOLUME [docker run args...] -- COMMAND...: one-off container with a home volume.
run_in() {
  local volume=$1
  shift
  local args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
  shift
  docker run --rm -v "$volume:/home/node" -e PI_OFFLINE=1 "${args[@]}" "$image" "$@"
}

sh_in() {
  local volume=$1 script=$2
  shift 2
  # CONTRACT_TRACE=1 traces the container-side scripts.
  run_in "$volume" "$@" -- bash -euo pipefail ${CONTRACT_TRACE:+-x} -c "$script"
}

dockerfile_arg() { sed -n "s/^ARG $1=//p" "$dockerfile" | head -1 | tr -d '"'; }

docker image inspect "$image" > /dev/null

# --- Static image contract ---------------------------------------------------
manifest=$(docker run --rm --entrypoint cat "$image" /opt/pi-web/image.json)
pi_web_version=$(jq -r .piWeb.version <<< "$manifest")
pi_version=$(jq -r .pi.version <<< "$manifest")
[ "$pi_web_version" = "$(dockerfile_arg PI_WEB_VERSION)" ] || fail "image PI WEB $pi_web_version != Dockerfile pin"
[ "$(jq -r .piWeb.commit <<< "$manifest")" = "$(dockerfile_arg PI_WEB_COMMIT)" ] || fail "image commit != Dockerfile pin"
pass "manifest matches the Dockerfile pins (PI WEB $pi_web_version, Pi $pi_version)"

docker run --rm --entrypoint bash "$image" -euo pipefail -c '
  for binary in pi pi-web pi-web-server pi-web-sessiond pi-web-container pi-login \
                node npm git gh jq rg curl tini uv uvx python3 ast-grep ssh; do
    command -v "$binary" > /dev/null || { echo "missing binary: $binary" >&2; exit 1; }
  done
  test "$(id -u):$(id -g)" = "1000:1000"
  test "$HOME" = /home/node
  for file in /opt/pi-web/defaults/*; do
    test "$(stat -c %a:%u "$file")" = 444:0
  done
  test "$(git config --system --get credential.https://github.com.helper)" = "!gh auth git-credential"
'
pass "required binaries, non-root user, read-only defaults"

[ "$(docker run --rm --entrypoint pi "$image" --version)" = "$pi_version" ] || fail "pi --version"
globals=$(docker run --rm --entrypoint npm "$image" ls --global --prefix /opt/pi-web/global --depth=0)
grep -Fq "@jmfederico/pi-web@$pi_web_version" <<< "$globals" || fail "global pi-web is not $pi_web_version"
selected=$(docker run --rm --entrypoint bash "$image" -c 'jq -r .version "$PI_WEB_PI_PACKAGE_DIR/package.json"')
[ "$selected" = "$pi_version" ] || fail "PI WEB's selected Pi runtime is $selected, expected $pi_version"
pass "PI WEB and the Pi runtime it selects match the release lockfile"

# --- prepare: defaults on a fresh volume ------------------------------------
new_volume defaults
run_in "$home" -- prepare
sh_in "$home" '
  agent=$HOME/.pi/agent
  test ! -e "$agent/models.json"
  test ! -e "$agent/mcp.json"
  jq -e --slurpfile image /opt/pi-web/pi-packages/image-packages.json ".packages == \$image[0]" "$agent/settings.json" > /dev/null
  if [ -d /opt/pi-web/pi-packages/node_modules/@gotgenes/pi-permission-system ]; then
    test "$(readlink "$agent/extensions/pi-permission-system/config.json")" = /opt/pi-web/defaults/permissions.json
    jq -e ".permission.path[\"**/.pi/agent/auth.json\"] == \"deny\"" /opt/pi-web/defaults/permissions.json > /dev/null
  fi
  test -d "$HOME/projects"
  test "$(stat -c %a "$agent")" = 700
'
docker run --rm -i -v "$home:/home/node" -e PI_OFFLINE=1 --entrypoint node "$image" \
  --input-type=module - < "$here/in-image.mjs"
pass "prepare registers image packages and the default policy; Pi loads them"

# --- prepare keeps user settings and is idempotent ---------------------------
new_volume settings
sh_in "$home" '
  mkdir -p "$HOME/.pi/agent"
  printf "%s" "{\"defaultProjectTrust\":\"never\",\"packages\":[\"npm:user-package@1.0.0\",\"/opt/pi-web/pi-packages/node_modules/removed-package\"]}" \
    > "$HOME/.pi/agent/settings.json"
  pi-web-container prepare
  first=$(cat "$HOME/.pi/agent/settings.json")
  pi-web-container prepare
  test "$first" = "$(cat "$HOME/.pi/agent/settings.json")"
  jq -e --slurpfile image /opt/pi-web/pi-packages/image-packages.json "
    .defaultProjectTrust == \"never\"
    and .packages == (\$image[0] + [\"npm:user-package@1.0.0\"])
  " "$HOME/.pi/agent/settings.json" > /dev/null
'
pass "prepare keeps user settings and packages, drops stale image paths, is idempotent"

# --- LLM gateway from environment --------------------------------------------
new_volume gateway
gateway_key="contract-dummy-llm-key-$suffix"
gateway_env=(-e PI_WEB_LLM_BASE_URL=https://llm.example.invalid/v1
  -e "PI_WEB_LLM_API_KEY=$gateway_key" -e "PI_WEB_LLM_MODELS=model-a, model-b")
sh_in "$home" 'mkdir -p "$HOME/.pi/agent" && echo "{\"providers\":{}}" > "$HOME/.pi/agent/models.json"'
run_in "$home" "${gateway_env[@]}" -- prepare
sh_in "$home" '
  agent=$HOME/.pi/agent
  jq -e "
    .providers.gateway == {
      baseUrl: \"https://llm.example.invalid/v1\",
      api: \"openai-completions\",
      apiKey: \"\$PI_WEB_LLM_API_KEY\",
      models: [{id: \"model-a\"}, {id: \"model-b\"}]
    }" "$agent/models.json" > /dev/null
  test "$(stat -c %a "$agent/models.json")" = 600
  ls "$agent"/models.json.bak.* > /dev/null
  ! grep -rqF "$KEY" "$HOME"
' -e "KEY=$gateway_key"
listed=$(run_in "$home" "${gateway_env[@]}" -- pi --list-models gateway 2>&1)
grep -q "model-a" <<< "$listed" || fail "Pi does not list the gateway models: $listed"
grep -q "model-b" <<< "$listed" || fail "Pi does not list the gateway models: $listed"
run_in "$home" -- prepare
sh_in "$home" 'test ! -e "$HOME/.pi/agent/models.json" && test ! -e "$HOME/.pi/agent/models.json.pi-web-container"'
pass "gateway env generates a key-free models.json Pi accepts; unsetting it removes the file"

# --- MCP server from environment ---------------------------------------------
new_volume mcp
mcp_key="contract-dummy-mcp-key-$suffix"
run_in "$home" -e PI_WEB_MCP_URL=https://mcp.example.invalid/mcp -e "PI_WEB_MCP_API_KEY=$mcp_key" -- prepare
sh_in "$home" '
  jq -e ".mcpServers.gateway == {
    url: \"https://mcp.example.invalid/mcp\",
    headers: {Authorization: \"Bearer \${PI_WEB_MCP_API_KEY}\"}
  }" "$HOME/.pi/agent/mcp.json" > /dev/null
  ! grep -rqF "$KEY" "$HOME"
' -e "KEY=$mcp_key"
pass "MCP env generates a key-free mcp.json"

# --- Mounted files and conflicts ---------------------------------------------
new_volume files
sh_in "$home" '
  mkdir -p "$HOME/config"
  echo "{\"providers\":{}}" > "$HOME/config/models.json"
  echo "{\"mcpServers\":{}}" > "$HOME/config/mcp.json"
  echo "{\"permission\":{\"*\":\"allow\"}}" > "$HOME/config/permissions.json"
  PI_WEB_MODELS_FILE=$HOME/config/models.json PI_WEB_MCP_FILE=$HOME/config/mcp.json \
    PI_WEB_PERMISSIONS_FILE=$HOME/config/permissions.json pi-web-container prepare
  agent=$HOME/.pi/agent
  test "$(readlink "$agent/models.json")" = "$HOME/config/models.json"
  test "$(readlink "$agent/mcp.json")" = "$HOME/config/mcp.json"
  if [ -d /opt/pi-web/pi-packages/node_modules/@gotgenes/pi-permission-system ]; then
    test "$(readlink "$agent/extensions/pi-permission-system/config.json")" = "$HOME/config/permissions.json"
    PI_WEB_PERMISSIONS_FILE= pi-web-container prepare
    test ! -e "$agent/extensions/pi-permission-system/config.json"
  fi
  if PI_WEB_MODELS_FILE=$HOME/config/models.json PI_WEB_LLM_BASE_URL=https://x.invalid \
       PI_WEB_LLM_MODELS=m pi-web-container prepare 2> /dev/null; then
    echo "conflicting model settings were accepted" >&2; exit 1
  fi
'
pass "mounted files are linked; conflicting settings are rejected"

# --- Split services: sessiond and server share one home volume ----------------
wait_healthy() {
  local container=$1 role=$2
  for _ in $(seq 1 60); do
    docker exec "$container" pi-web-container health "$role" 2> /dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" = true ] || break
    sleep 1
  done
  docker logs "$container" >&2 || true
  fail "$role in $container did not become healthy"
}

new_volume split
sessiond="pi-web-contract-sessiond-$suffix"
server="pi-web-contract-server-$suffix"
containers+=("$sessiond" "$server")
docker run -d --name "$sessiond" -v "$home:/home/node" -e PI_OFFLINE=1 "$image" sessiond > /dev/null
wait_healthy "$sessiond" sessiond
docker run -d --name "$server" -v "$home:/home/node" -e PI_OFFLINE=1 "$image" server > /dev/null
wait_healthy "$server" server
docker exec "$server" pi-web-container health sessiond || fail "server container cannot reach the sessiond socket"
runtime=$(docker exec "$server" curl -fsS http://127.0.0.1:8504/api/pi-web/runtime)
jq -e --arg pi "$pi_version" '.components.sessiond.available == true and .components.sessiond.piVersion == $pi' \
  <<< "$runtime" > /dev/null \
  || fail "server does not see a running sessiond: $runtime"
pass "split sessiond + server start and connect over the shared socket"

status=$(docker exec "$server" curl -fsS http://127.0.0.1:8504/api/pi-web/status)
jq -e '.components.web.installation.kind == "npm-global" and .components.sessiond.installation.kind == "npm-global"' \
  <<< "$status" > /dev/null \
  || fail "PI WEB does not detect a packaged npm-global install: $status"
webmanifest=$(docker exec "$server" curl -fsS http://127.0.0.1:8504/manifest.webmanifest)
jq -e '.name | endswith("(dev)") | not' <<< "$webmanifest" > /dev/null \
  || fail "PI WEB presents the image as a dev deployment: $webmanifest"
pass "PI WEB detects the image as a packaged install, not a dev checkout"

# --- All-in-one container ------------------------------------------------------
new_volume all
all="pi-web-contract-all-$suffix"
containers+=("$all")
docker run -d --name "$all" -v "$home:/home/node" -e PI_OFFLINE=1 "$image" > /dev/null
wait_healthy "$all" server
wait_healthy "$all" sessiond
runtime=$(docker exec "$all" curl -fsS http://127.0.0.1:8504/api/pi-web/runtime)
jq -e --arg pi "$pi_version" '.components.sessiond.available == true and .components.sessiond.piVersion == $pi' \
  <<< "$runtime" > /dev/null \
  || fail "all-in-one server does not see a running sessiond: $runtime"
docker stop -t 20 "$all" > /dev/null
pass "all-in-one container serves the UI and stops on TERM"

echo "PI WEB image contract passed: $image"
