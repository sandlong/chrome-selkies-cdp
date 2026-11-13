# chrome-selkies-cdp

[![Docker publish](https://github.com/sandlong/chrome-selkies-cdp/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/sandlong/chrome-selkies-cdp/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A thin downstream of [linuxserver/chrome](https://github.com/linuxserver/docker-chrome) (`lscr.io/linuxserver/chrome`): Google Chrome in a container, streamed to your browser through the Selkies web desktop. Upstream docs: <https://docs.linuxserver.io/images/docker-chrome/>.

This image does not fork or reimplement the upstream desktop stack. It layers three optional features on top, each switched on by environment variables, so upstream updates stay easy to track:

1. **Scheduled restart**: recycle the container on a cron schedule.
2. **CDP**: expose Chrome DevTools Protocol for automation clients.
3. **MCP**: serve a remote Streamable HTTP MCP endpoint for the same browser.

With every feature off, the container behaves like plain `linuxserver/chrome`.

```text
ghcr.io/sandlong/chrome-selkies-cdp:latest
```

The image is rebuilt automatically whenever the upstream `linuxserver/chrome` image or `@playwright/mcp` publishes a new release. Every build also gets an immutable tag of the form `upstream-<digest>-mcp-<version>`.

## 1. Scheduled restart

Long-running Chrome sessions slowly accumulate memory and stale state. Setting `CONTAINER_RESTART_CRON` makes the container recycle itself on a schedule, with no host cron, Docker socket or sidecar.

```bash
-e CONTAINER_RESTART_CRON='0 4 * * *'   # every day at 04:00 in TZ
```

How it works: at boot, the image adds one managed entry to the container's root crontab, keeping any other cron jobs. The schedule is standard five-field cron, evaluated in the container's `TZ`. The aliases `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly` and `@annually` also work. At the scheduled time, the job asks s6-overlay (PID 1) to halt, which stops every supervised service cleanly and lets the container exit.

> [!IMPORTANT]
> **The restart depends on Docker's restart policy.** A container cannot recreate itself without talking to the Docker daemon. The halt only stops the container; Docker is what starts it again. Run with `--restart unless-stopped` or `--restart always` (Compose: `restart: unless-stopped`).
>
> - Without a restart policy, the container stops at the scheduled time and stays stopped.
> - `--restart on-failure` does not work either: a scheduled halt is a clean exit with code `0`, which `on-failure` ignores.
> - This restarts the same container with the same config and image. It does not pull a newer image or apply changed env vars; use Watchtower or recreate the container for that.
>
> `@reboot` is rejected, because it would restart the container immediately after every start. An invalid schedule fails the init step loudly rather than being silently ignored. Each scheduled restart is logged to `/config/log/container-restart.log`.

## 2. CDP

Set `ENABLE_CDP=true` to let automation clients (Playwright, Puppeteer, agent frameworks such as Hermes) drive the same visible Chrome you see in the web UI.

```bash
-e ENABLE_CDP=true -p 127.0.0.1:9222:9222
curl http://127.0.0.1:9222/json/version
```

How it works: Chrome listens for DevTools only on container loopback (`127.0.0.1:$CDP_INTERNAL_PORT`, default `9223`), and `socat` forwards the container port `$CDP_PORT` (default `9222`) to it. A root init step creates the profile and log directories and fixes their ownership before Chrome starts, so a host bind mount created by Docker works without any manual `mkdir` or `chown`.

> [!IMPORTANT]
> **CDP needs its own Chrome user profile.** Since Chrome 136, `--remote-debugging-port` is ignored when Chrome runs on its default user data directory, a protection against cookie theft. So with CDP on, Chrome is launched with a dedicated, explicit profile at `CDP_PROFILE_DIR` (default `/config/cdp-profile`) instead of upstream's `/config/.config/google-chrome`.
>
> - Logins, extensions and settings from the upstream profile **do not carry over**. Sign in again inside the CDP profile, and toggling `ENABLE_CDP` switches you between the two profiles.
> - Mount **one** volume at `/config` only. Do not bind a separate path onto `/config/cdp-profile`.

To keep the dedicated profile everywhere, the image also patches the launch paths that would otherwise fall back to the default profile:

- Upstream's `/usr/bin/wrapped-chrome` passes a bare `--user-data-dir` with no value, which can swallow the following debugging flags. It is replaced by a shim into this image's launcher; the original stays at `/usr/bin/wrapped-chrome.real` and is used when CDP is off.
- The desktop right-click menu (Labwc `menu.xml`) is rewritten to the same launcher, so relaunching Chrome from the menu keeps CDP and the dedicated profile.
- Stale `Singleton*` lock files left by a Chrome crash are cleared on launch whenever no Chrome process is running; otherwise the next launch would exit immediately.

Launch arguments are recorded in `/config/log/cdp-launch.log`.

> [!WARNING]
> CDP has no authentication at all. Anyone who can reach the port has full control of the browser, including every logged-in session. Bind it to `127.0.0.1` or a private network, never the public internet.

## 3. MCP

Set `ENABLE_MCP=true` (requires `ENABLE_CDP=true`) to run [Playwright MCP](https://github.com/microsoft/playwright-mcp) inside the container, attached to the same Chrome over CDP. Remote AI agents can then drive the visible, logged-in browser through a Streamable HTTP MCP endpoint, without speaking CDP:

```text
http(s)://<host>:3000|3001/<MCP_SECRET_PATH>/mcp
```

How it works: Playwright MCP listens only on container loopback (`127.0.0.1:$MCP_INTERNAL_PORT`, default `8931`). At boot, the image injects one `location /<MCP_SECRET_PATH>/` block into the upstream nginx that already serves the web UI on ports `3000` (HTTP) and `3001` (HTTPS), so there is no extra port to publish. Requests to any other path never reach the MCP server.

> [!IMPORTANT]
> **The secret path is the only credential.** There is no token, header check or OAuth.
>
> - nginx turns basic auth **off** for the secret-path location (MCP clients cannot answer a basic-auth prompt), so `CUSTOM_USER` / `PASSWORD` protect the web UI but not the MCP endpoint.
> - Anyone who knows the full URL has full control of the browser. Treat the URL like a password: it can leak through client config files, shell history and reverse-proxy or tunnel access logs.
> - Port `3000` is plain HTTP. Over any untrusted network, put TLS in front (a tunnel or reverse proxy) or use `3001`; otherwise the secret travels in clear text.
> - `MCP_SECRET_PATH` must be 24-128 characters of `[A-Za-z0-9_-]`; generate one with `openssl rand -hex 24`. Rotate it by changing the env var and recreating the container. If it is missing or invalid, or CDP is off, the bridge stays disabled, the browser starts normally, and `init-mcp-bridge` logs the reason.
>
> For stronger protection, put real authentication (an OAuth-capable gateway, Cloudflare Access, a VPN) in front of the endpoint.

Client configuration:

```json
{ "mcpServers": { "chrome": { "url": "https://chrome-mcp.example.com/<MCP_SECRET_PATH>/mcp" } } }
```

Notes:

- `browser_take_screenshot` returns the image inline in the MCP response, so remote clients can see it, **unless the client passes a `filename`**. Then only a server-side path comes back. Files are always also written to `MCP_OUTPUT_DIR`.
- That directory grows over time. Cap it with Playwright MCP's own eviction flag, e.g. `MCP_EXTRA_ARGS="--output-max-size 209715200"` (about 200 MB, oldest files deleted first).
- MCP sessions and CDP clients share one browser. Concurrent agents can fight over tabs and focus, so prefer one active controller at a time.

## Environment variables

Added by this image:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONTAINER_RESTART_CRON` | empty (off) | Cron schedule for a graceful in-container recycle; uses `TZ`; needs a Docker restart policy |
| `ENABLE_CDP` | `false` | Launch Chrome with the dedicated profile and CDP forwarding |
| `CDP_PORT` | `9222` | Container port that forwards to Chrome's DevTools |
| `CDP_INTERNAL_PORT` | `9223` | Loopback DevTools port Chrome listens on |
| `CDP_PROFILE_DIR` | `/config/cdp-profile` | Chrome user data dir used when CDP is on |
| `CDP_LOG_DIR` | `/config/log` | Logs for the forwarder, launches and scheduled restarts |
| `ENABLE_MCP` | `false` | Enable the MCP bridge (requires `ENABLE_CDP=true`) |
| `MCP_SECRET_PATH` | empty | Secret URL prefix, 24-128 chars of `[A-Za-z0-9_-]`; required for MCP |
| `MCP_INTERNAL_PORT` | `8931` | Loopback port Playwright MCP listens on |
| `MCP_OUTPUT_DIR` | `/config/mcp-output` | Where screenshots, PDFs and other MCP output files are written |
| `MCP_EXTRA_ARGS` | empty | Extra flags passed to Playwright MCP unchanged (e.g. `--caps vision,pdf`, `--output-max-size <bytes>`) |

Upstream variables you will still use:

| Variable | Meaning |
| --- | --- |
| `PUID` / `PGID` | Host UID/GID mapped to the container user `abc`; use a normal user such as `1000`, not `0` |
| `TZ` | Timezone; also used by `CONTAINER_RESTART_CRON` |
| `CUSTOM_USER` / `PASSWORD` | Basic auth for the web UI |
| `CHROME_CLI` | Extra Chrome flags, passed through unchanged |
| `NO_DECOR` | Hide window decorations so Chrome fills the desktop |
| `SELKIES_MANUAL_WIDTH` / `SELKIES_MANUAL_HEIGHT` | Fixed display size |

## Full `docker run` example

All three features enabled, every port bound to localhost. Expose the web UI and the MCP endpoint through your own tunnel or reverse proxy. Docker creates `/root/chrome/config` on first run and the image fixes its ownership. A Compose equivalent is in [`docker-compose.yml`](./docker-compose.yml).

```bash
docker run -d \
  --name chrome \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  --shm-size 8g \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Asia/Singapore \
  -e CUSTOM_USER=admin \
  -e PASSWORD='change-me' \
  -e NO_DECOR=1 \
  -e CONTAINER_RESTART_CRON='0 4 * * *' \
  -e ENABLE_CDP=true \
  -e CDP_PORT=9222 \
  -e CDP_PROFILE_DIR=/config/cdp-profile \
  -e ENABLE_MCP=true \
  -e MCP_SECRET_PATH="$(openssl rand -hex 24)" \
  -e MCP_EXTRA_ARGS='--output-max-size 209715200' \
  -p 127.0.0.1:3000:3000 \
  -p 127.0.0.1:3001:3001 \
  -p 127.0.0.1:9222:9222 \
  -v /root/chrome/config:/config \
  ghcr.io/sandlong/chrome-selkies-cdp:latest

# Web UI:        https://127.0.0.1:3001/
# CDP:           curl http://127.0.0.1:9222/json/version
# MCP endpoint:  http://127.0.0.1:3000/<MCP_SECRET_PATH>/mcp
# Read the generated secret back with:
docker inspect chrome --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^MCP_SECRET_PATH='
```
