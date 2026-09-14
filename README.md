# chrome-selkies-cdp

[![Docker publish](https://github.com/sandlong/chrome-selkies-cdp/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/sandlong/chrome-selkies-cdp/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A very thin downstream image built on top of `lscr.io/linuxserver/chrome`, with two optional extras: enable Chrome CDP and forward it to port `9222` when requested, and schedule a periodic container recycle from inside the container.

## What changed from upstream

The base image stays `linuxserver/chrome`. This repository only adds `socat`, a tiny startup wrapper, and a small root init that prepares the CDP profile directory.

When `ENABLE_CDP=true`:

- A root-side `init-cdp-profile` step creates `CDP_PROFILE_DIR` / `CDP_LOG_DIR` and chowns them to `abc` **before** Chrome starts. This means a host bind mount path can be created automatically by Docker (root-owned) and still work without a manual `mkdir`/`chown` on the host.
- Chrome is launched **directly** with an explicit valued `--user-data-dir=$CDP_PROFILE_DIR`. Upstream `wrapped-chrome` hardcodes a bare `--user-data-dir` with no value; Chrome then treats the next argv as that path and can swallow/drop `--remote-debugging-*` flags. The original upstream script is kept as `wrapped-chrome.real`.
- `/usr/bin/wrapped-chrome` is replaced by a shim that always calls `start-cdp-chrome.sh`, so **right-click menu / manual relaunch** also keep the CDP profile instead of falling back to `/config/.config/google-chrome`.
- Labwc menu defaults and any existing `menu.xml` / `menu.xml.bak` are rewritten to the CDP launcher on boot.
- Dedicated profile is required so Chrome 136+ remote debugging rules are satisfied.
- Chrome listens for DevTools on loopback (`127.0.0.1:$CDP_INTERNAL_PORT`).
- `socat` forwards container port `$CDP_PORT` (default `9222`) to that internal loopback-only DevTools port.

When `ENABLE_CDP=false`:

- The container behaves like normal `linuxserver/chrome` via `wrapped-chrome.real`.
- No CDP listener is started.

When `CONTAINER_RESTART_CRON` is set:

- The image adds one managed entry to root's existing crontab without replacing unrelated cron jobs.
- The schedule uses standard five-field cron syntax (for example `0 4 * * *`) and the container's `TZ`.
- At the scheduled time, the job asks s6-overlay to shut the container down cleanly.
- Docker's restart policy then starts the same container again. No host cron, Docker socket, sidecar, or other scheduler is required.

The container cannot literally recreate itself without talking to the Docker daemon, so a Docker restart policy such as `--restart unless-stopped` (or Compose `restart: unless-stopped`) is required for scheduled restart to complete. `@reboot` is intentionally rejected to prevent a restart loop.

## One-shot docker run (no pre-created host folders)

As root on the host, this is enough. Docker will create the bind path; the image fixes ownership for `abc` at boot:

```bash
docker rm -f chrome 2>/dev/null || true
rm -rf /root/chrome

docker run -d \
  --name chrome \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  --shm-size=8g \
  --dns 1.1.1.1 \
  --dns 8.8.8.8 \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Asia/Singapore \
  -e CUSTOM_USER= \
  -e PASSWORD='change-me' \
  -e NO_DECOR=1 \
  -e ENABLE_CDP=true \
  -e CDP_PORT=9222 \
  -e CDP_PROFILE_DIR=/config/cdp-profile \
  -e CONTAINER_RESTART_CRON='0 4 * * *' \
  -p 3000:3000 \
  -p 3001:3001 \
  -p 9222:9222 \
  -v /root/chrome/config:/config \
  ghcr.io/sandlong/chrome-selkies-cdp:latest
```

Important:

- Use **one** volume only: `-v /host/path:/config`. Do **not** also bind a nested path onto `/config/cdp-profile`.
- `PUID`/`PGID` should match a normal host user (e.g. `1000`). Do not use `0`.
- You do **not** need `mkdir`/`chown` on the host first when using this image's `init-cdp-profile`.

Open the browser UI at `https://localhost:3001/`.

Check CDP with:

```bash
curl http://127.0.0.1:9222/json/version
```

## Docker Compose

```yaml
services:
  chrome-selkies-cdp:
    image: ghcr.io/sandlong/chrome-selkies-cdp:latest
    ports:
      - "3001:3001"
      - "9222:9222"
    environment:
      TZ: Asia/Singapore
      CUSTOM_USER: change-me
      PASSWORD: change-me
      ENABLE_CDP: "true"
      CONTAINER_RESTART_CRON: "0 4 * * *"
    volumes:
      - chrome-config:/config
    restart: unless-stopped

volumes:
  chrome-config:
```

Named volumes also work; the same single-`/config` rule applies.

## Environment variables added by this repo

| Variable | Default | Meaning |
| --- | --- | --- |
| `ENABLE_CDP` | `false` | Enable CDP and port `9222` forwarding |
| `CDP_PORT` | `9222` | External forwarded CDP port |
| `CDP_INTERNAL_PORT` | `9223` | Internal loopback CDP port used by Chrome |
| `CDP_PROFILE_DIR` | `/config/cdp-profile` | Profile path used when CDP is enabled |
| `CDP_LOG_DIR` | `/config/log` | Log directory for the `socat` forwarder |
| `CONTAINER_RESTART_CRON` | empty (disabled) | Standard 5-field cron schedule for an in-container graceful recycle; uses `TZ` and requires a Docker restart policy |

`CONTAINER_RESTART_CRON` also accepts the usual non-boot aliases `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, and `@hourly`. `@reboot` is rejected because it would restart the container immediately after every start.

## Important upstream variables you will still use

| Variable | Meaning |
| --- | --- |
| `CUSTOM_USER` / `PASSWORD` | Basic auth for the web UI |
| `CHROME_CLI` | Extra Chrome flags passed through unchanged |
| `TZ` | Timezone |
| `PUID` / `PGID` | Host UID/GID mapped to container user `abc` |
| `SELKIES_MANUAL_WIDTH` / `SELKIES_MANUAL_HEIGHT` | Display size |
| `PIXELFLUX_WAYLAND` | Upstream Wayland toggle |

## Notes

This repo intentionally does not fork or reimplement the upstream desktop stack. It only layers a CDP-on-demand wrapper on top of `linuxserver/chrome` so upstream updates remain easy to track.

CDP access is effectively full browser control. Do not expose port `9222` directly to the public internet.
