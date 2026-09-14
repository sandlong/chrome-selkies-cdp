Hermes can attach to the local Chrome CDP endpoint exposed by this container.

Typical flow:

1. Start the container with `ENABLE_CDP=true` and confirm CDP is live:

   curl http://127.0.0.1:9222/json/version

2. In Hermes, point the browser CDP URL at:

   BROWSER_CDP_URL=ws://127.0.0.1:9222

   or connect manually with:

   /browser connect ws://127.0.0.1:9222

3. Open the Chrome web UI to watch the live session:

   https://127.0.0.1:3001/

Important: if Hermes and OpenClaw both attach to the same browser at the same time,
page focus and tab state can interfere with each other. Prefer one active controller
at a time, or run separate container instances.
