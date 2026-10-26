# Optional CDP -> MCP bridge (Microsoft Playwright MCP, Streamable HTTP).
# Built in a throwaway Node stage; only the node binary and the installed
# package tree are copied into the final image. Bump the version deliberately.
FROM node:22-bookworm-slim AS mcp

ARG PLAYWRIGHT_MCP_VERSION=0.0.83
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN npm install \
      --prefix /opt/playwright-mcp \
      --omit=dev --no-audit --no-fund \
      "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
 && npm cache clean --force

FROM lscr.io/linuxserver/chrome:latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && if [ -f /usr/bin/wrapped-chrome ]; then \
      cp -a /usr/bin/wrapped-chrome /usr/bin/wrapped-chrome.real; \
    fi

COPY --from=mcp /usr/local/bin/node /usr/local/bin/node
COPY --from=mcp /opt/playwright-mcp /opt/playwright-mcp

COPY root/ /

RUN chmod +x \
    /usr/local/bin/start-cdp-chrome.sh \
    /usr/local/bin/scheduled-container-restart.sh \
    /usr/bin/wrapped-chrome \
    /defaults/autostart \
    /defaults/autostart_wayland \
    /etc/s6-overlay/s6-rc.d/init-cdp-profile/run \
    /etc/s6-overlay/s6-rc.d/init-restart-cron/run \
    /etc/s6-overlay/s6-rc.d/init-mcp-bridge/run \
    /etc/s6-overlay/s6-rc.d/svc-mcp-bridge/run \
 && /usr/local/bin/node /opt/playwright-mcp/node_modules/@playwright/mcp/cli.js --version
