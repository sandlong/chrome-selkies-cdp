FROM lscr.io/linuxserver/chrome:latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && if [ -f /usr/bin/wrapped-chrome ]; then \
      cp -a /usr/bin/wrapped-chrome /usr/bin/wrapped-chrome.real; \
    fi

COPY root/ /

RUN chmod +x \
    /usr/local/bin/start-cdp-chrome.sh \
    /usr/local/bin/scheduled-container-restart.sh \
    /usr/bin/wrapped-chrome \
    /defaults/autostart \
    /defaults/autostart_wayland \
    /etc/s6-overlay/s6-rc.d/init-cdp-profile/run \
    /etc/s6-overlay/s6-rc.d/init-restart-cron/run
