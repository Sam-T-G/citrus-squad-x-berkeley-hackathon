"""Laptop side of the internet fallback: pull belt cues from the relay, drive the Arduino.

When the phone cannot reach the laptop on a shared network, the phone sends its cue
stream to the hosted relay (relay.py) over WebSocket instead, and this client pulls
that stream down and writes it to the Arduino over USB serial.

It reuses the local server's `Hub` verbatim, so the serial behaviour is identical to
the direct path: the same lc2_to_command mapping, change-only writes, the silence
watchdog, mock fallback, and serial reconnect. Only the source of the frames differs
(a WebSocket from the relay instead of a UDP socket from the phone).

Run:
    RELAY_URL=wss://your-relay.fly.dev/recv python relay_client.py
    RELAY_URL=wss://your-relay.fly.dev/recv RELAY_TOKEN=secret python relay_client.py
    SERIAL_PORT=mock RELAY_URL=ws://localhost:8090/recv python relay_client.py   # local test
"""

from __future__ import annotations

import asyncio
import os
import sys

import websockets

import app  # reuse Hub, lc2_to_command, serial writer, watchdog


def relay_url() -> str:
    url = os.environ.get("RELAY_URL", "ws://localhost:8090/recv").strip()
    token = os.environ.get("RELAY_TOKEN", "").strip()
    if token and "token=" not in url:
        url += ("&" if "?" in url else "?") + f"token={token}"
    return url


async def pump(hub: "app.Hub", url: str) -> None:
    """Stay connected to the relay, feeding every received frame into the hub. Reconnects
    with backoff so a relay restart or a flaky link recovers on its own."""
    backoff = 1.0
    while True:
        try:
            async with websockets.connect(url, ping_interval=10, ping_timeout=10) as ws:
                print(f"[relay-client] connected to {url}")
                backoff = 1.0
                async for message in ws:
                    if isinstance(message, (bytes, bytearray)) and len(message) >= 4:
                        hub.last_src = "relay"
                        hub.submit(bytes(message[:4]))
        except Exception as exc:
            print(f"[relay-client] disconnected: {exc!r}; retrying in {backoff:.0f}s")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 10.0)


async def main() -> int:
    url = relay_url()
    hub = app.Hub()
    mode = "MOCK (no Arduino)" if hub.mock else f"serial {hub.port} @ {app.SERIAL_BAUD}"
    print(f"[relay-client] belt output: {mode}")
    print(f"[relay-client] relay: {url}")
    writer = asyncio.create_task(hub.writer())
    try:
        await pump(hub, url)
    finally:
        writer.cancel()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\n[relay-client] stopped")
        sys.exit(0)
