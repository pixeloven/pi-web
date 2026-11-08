# PI WEB container image

A portable image of [PI WEB](https://github.com/jmfederico/pi-web), published as `ghcr.io/pixeloven/pi-web`, for Docker Compose or Kubernetes. It builds upstream PI WEB from an exact release tag and adds a small entrypoint, `pi-web-container`, that turns environment variables into Pi configuration at start-up.

This is separate from the upstream [`docker/`](../README.md) setup. That one installs PI WEB on a Docker host with the Docker socket, host directory mounts, and host command access. This image mounts nothing from the host: all state lives in one volume.

> [!WARNING]
> PI WEB has no login and runs model-directed commands as the container user. Run it for one trusted user. Publish the port only on localhost, or put an authenticating proxy, VPN, or SSH tunnel in front of it.

## Quick start

```bash
docker run -d --name pi-web \
  -p 127.0.0.1:8504:8504 \
  -v pi-web-home:/home/node \
  -e ANTHROPIC_API_KEY \
  ghcr.io/pixeloven/pi-web:latest
```

Open <http://127.0.0.1:8504>. The default command, `all`, runs the session daemon and the web server in one container. Pass any [provider key](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md) Pi supports, or configure a [model gateway](#model-gateway).

## Docker Compose

[`examples/compose/`](examples/compose/) runs the session daemon and the web server as separate services sharing one volume, so restarting the web service does not stop active sessions:

```bash
cd docker/image/examples/compose
cp settings.env.example settings.env   # optional
cp pi-web.env.example pi-web.env       # optional
docker compose up -d
```

Non-secret settings, including the [PI WEB settings](#pi-web-settings) the web server reads, go in `settings.env`, which both services read. Secrets go in `pi-web.env`, which only the `sessiond` service reads.

## Kubernetes

[`examples/kubernetes/`](examples/kubernetes/) is a minimal Deployment with two containers in one pod, a PersistentVolumeClaim for the home directory, and a ClusterIP Service. It has no Ingress, namespace, or storage class; add those for your cluster.

Settings are read from an optional ConfigMap named `pi-web-config` and secrets from an optional Secret named `pi-web-secrets`. Create the ones you need, then apply:

```bash
kubectl create configmap pi-web-config \
  --from-literal=PI_WEB_LLM_BASE_URL=https://llm.example.com/v1 \
  --from-literal=PI_WEB_LLM_MODELS=model-one,model-two
kubectl create secret generic pi-web-secrets \
  --from-literal=PI_WEB_LLM_API_KEY="$PI_WEB_LLM_API_KEY"

kubectl apply -k docker/image/examples/kubernetes/
kubectl port-forward service/pi-web 8504:8504
```

Restart the pod after changing either object. Pin `image:` to a version and digest instead of `latest`.

## Commands

The entrypoint is `pi-web-container`. Its first argument selects what the container runs:

| Command | Runs |
| --- | --- |
| `all` (default) | Prepares configuration, then runs `pi-web-sessiond` and `pi-web-server`. If either exits, the container stops. |
| `sessiond` | Prepares configuration, then runs the session daemon. |
| `server` | Runs the web/API server. |
| `prepare` | Applies the configuration below and exits. |
| `health server`, `health sessiond` | Exits 0 when that process answers its health endpoint. |
| anything else | Runs that command, for example `pi --version`. |

`server` and `sessiond` find each other through the session daemon socket, by default `$PI_WEB_DATA_DIR/sessiond.sock` in the shared home volume. Set the same `PI_WEB_SESSIOND_SOCKET` on both to move it; the Kubernetes example puts it on a pod-local `emptyDir`.

## Configuration

Preparation changes files only in the Pi agent directory (`~/.pi/agent`). Generated files reference secrets by environment variable name and Pi reads the value when it needs it, so keys are never written to the volume. Each generated or linked file has a `.pi-web-container` stamp next to it. When you remove a setting, the file it produced is removed at the next start. A file you changed by hand is kept: it is moved to `<name>.bak.<timestamp>` before being replaced, and left in place when its setting is removed.

### Model gateway

Set these to add one OpenAI-compatible provider, for example an LLM gateway or a local inference server:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PI_WEB_LLM_BASE_URL` | — | API base URL, usually ending in `/v1`. Enables the provider. |
| `PI_WEB_LLM_MODELS` | — | Comma-separated model IDs. Required with the base URL. |
| `PI_WEB_LLM_API_KEY` | — | Secret. Sent as the API key. Omit it for servers without authentication. |
| `PI_WEB_LLM_PROVIDER` | `gateway` | Provider ID shown in the model picker. |
| `PI_WEB_LLM_PROVIDER_NAME` | — | Optional display name. |
| `PI_WEB_LLM_API` | `openai-completions` | Pi API type, for example `openai-responses` or `anthropic-messages`. |

For several providers, or per-model limits such as `contextWindow` and `reasoning`, mount a complete [`models.json`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md) and set `PI_WEB_MODELS_FILE` to its path instead. Its `apiKey` values can name an environment variable as `"$NAME"`.

### MCP servers

Pi connects to [MCP servers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md) natively. For one streamable-HTTP server:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PI_WEB_MCP_URL` | — | Server URL. Enables the server. |
| `PI_WEB_MCP_API_KEY` | — | Secret. Sent as `Authorization: Bearer …`. |
| `PI_WEB_MCP_NAME` | `gateway` | Server name; tools appear as `mcp__<name>__<tool>`. |

For more servers or stdio servers, mount an `mcp.json` and set `PI_WEB_MCP_FILE`. Header and `env` values can use `${NAME}`.

### Permissions

The default image includes [`@gotgenes/pi-permission-system`](https://www.npmjs.com/package/@gotgenes/pi-permission-system) with a baseline policy, [`defaults/permissions.json`](rootfs/opt/pi-web/defaults/permissions.json). It allows normal work and denies reading credential files such as `.env`, SSH keys, cloud credentials, and Pi's `auth.json`, as well as destructive commands such as `rm -rf /`, `sudo`, `gh repo delete`, and force pushes. Commands the extension cannot inspect, such as `bash -c`, `xargs`, or `find -exec`, ask for approval in the PI WEB session. It is a guardrail on what the agent asks to do, not a sandbox.

The policy is a read-only file owned by root and linked into the agent directory. To use your own, mount it and set `PI_WEB_PERMISSIONS_FILE` to its path. Set `PI_WEB_PERMISSIONS_FILE` to an empty value to manage `~/.pi/agent/extensions/pi-permission-system/config.json` yourself.

### PI WEB settings

All upstream [PI WEB settings](../../docs/config.md) work as environment variables. The image sets:

| Variable | Image value |
| --- | --- |
| `PI_WEB_HOST`, `PI_WEB_PORT` | `0.0.0.0`, `8504` |
| `PI_WEB_DEFAULTS_CONFIG` | `/opt/pi-web/defaults/config.json`, which lets the file browser open `/home/node/projects` |

Commonly used: `PI_WEB_DEFAULT_THEME` (for example `{"themeId":"themes:pi-web-light","auto":false}`), `PI_WEB_HOST_ACCESS` (hostname policy behind a proxy, for example `{"mode":"restricted","hosts":["pi.example.com"]}`), and `PI_WEB_INSTALLATION_NAME`. Settings changed in the UI are saved to `~/.config/pi-web/config.json` on the volume.

### Secrets

The image reads secrets only from the environment. None are required.

| Name | Used by |
| --- | --- |
| `PI_WEB_LLM_API_KEY` | The model gateway provider. |
| `PI_WEB_MCP_API_KEY` | The MCP server. |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, … | Pi's [built-in providers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md). |
| `GH_TOKEN` | `gh`, and `git` over HTTPS to github.com through the `gh` credential helper. |

Give secrets to the session daemon only; the web server does not need them. In the Compose example they go in `pi-web.env`; on Kubernetes, in the `pi-web-secrets` Secret.

### Provider sign-in

For subscription or OAuth providers, open a terminal in the session daemon container and run `pi-login`, then `/login`. It starts Pi without extensions, skills, or project files. The credential is saved to `~/.pi/agent/auth.json` on the volume. Restart the session daemon afterwards.

```bash
docker compose exec sessiond pi-login
kubectl exec -it deploy/pi-web -c sessiond -- pi-login
```

## Storage

Everything persistent is under `/home/node`, owned by UID and GID 1000:

| Path | Contents |
| --- | --- |
| `~/.pi/agent` | Pi sessions, credentials, settings, models, MCP config, user-installed Pi packages |
| `~/.pi-web` | PI WEB state: projects, archives, session daemon socket |
| `~/.config/pi-web/config.json` | Settings saved from the UI |
| `~/projects` | Repositories. Clone here, then add the folder as a project in PI WEB. |

Back up the volume as you would credentials: it contains `auth.json` and any tokens you configure. To run as another UID, make the volume writable by it; on Kubernetes set `runAsUser` and `fsGroup` together.

## Image contents

- PI WEB at the pinned release, with Pi core at the exact versions in that release's lockfile.
- Pi packages, installed under `/opt/pi-web/pi-packages` and registered in `~/.pi/agent/settings.json` at start-up so a volume never hides them. Packages you add with `pi install` stay in the volume and are kept. Default set: `@gotgenes/pi-permission-system`, `pi-subagents`, `pi-web-access`.
- Tools for agent sessions: `git`, `gh`, `ssh`, `rg`, `jq`, `curl`, `python3` with `venv` and `pip`, `uv`, `ast-grep`.

The image updates by replacing it. PI WEB's in-app update does not apply; pull a newer tag instead.

## Building

```bash
docker build -t pi-web:local docker/image
docker/image/test/image-contract.sh pi-web:local
```

The build needs network access to GitHub and npm. Build arguments:

| Argument | Default | Meaning |
| --- | --- | --- |
| `PI_WEB_VERSION` | `1.202611.1` | Upstream release tag to build, without the `v`. |
| `PI_WEB_COMMIT` | that tag's commit | The build fails if the tag resolves elsewhere. Empty skips the check. |
| `PI_WEB_REPO` | upstream repository | Git URL to build from. |
| `PI_PACKAGES` | three packages above | Space-separated exact `npm:<name>@<version>` Pi packages. Empty for none. |
| `NODE_IMAGE`, `UV_IMAGE`, `AST_GREP_VERSION` | see `Dockerfile` | Base image and tool pins. |

To upgrade PI WEB, change `PI_WEB_VERSION` and `PI_WEB_COMMIT` together, rebuild, and run the contract test. Pi core follows the new release's lockfile.

A stream-copy patch for session archiving on NFS or virtiofs storage, which reject `copy_file_range(2)`, remains on this repository's `harmony/*` branches. This image does not include it.

## Tags

CI builds and tests every change under `docker/image/` and publishes `linux/amd64` images:

| Tag | Published from |
| --- | --- |
| `latest`, `main`, `sha-<commit>` | Each push to `main` |
| `<PI WEB version>`, for example `1.202611.1` | Each push to `main`; moves when the image changes without a PI WEB upgrade |
| `<x.y.z>` | A pushed `image-v<x.y.z>` tag |

Tags move. For a fixed deployment, pin a digest.

## Testing

[`test/image-contract.sh`](test/image-contract.sh) checks an image without credentials or external services: pins and tool versions, configuration generation from the variables above, that keys are never written to disk, that Pi loads the image packages, and that split and all-in-one containers start and connect. CI runs it on every pull request that changes the image.
