"""Citrus Squad belt relay (internet fallback).

A tiny hosted forwarder for when the phone and the laptop cannot share a Wi-Fi
network. Both ends connect OUT to this relay over WebSocket on port 443 (which is
almost never blocked), and the relay passes each cue straight through in memory.
No database, no polling: a sender's frame is forwarded to every receiver as it
arrives, so the added latency is one internet round-trip, not a store-and-poll.

This is the LAST-resort path. The primary is the local UDP link (phone -> laptop
on the same network), which has ~1 ms latency and no cloud dependency. The relay
exists only so the demo survives a venue where no shared network is possible.

Roles (one process, two endpoints):
  /send   the phone connects here and sends 4-byte LC2 frames (or JSON debug)
  /recv   the laptop's relay_client connects here and receives those frames

It forwards the same 4 LC2 bytes the phone already builds, so the laptop receiver
runs the exact same lc2_to_command mapping as the local server. Nothing about the
belt logic changes; only the transport in the middle does.

Optional shared secret: set RELAY_TOKEN and both ends must pass ?token=... so a
stray client cannot drive the belt. Unset = open (fine for a short demo).

Run locally:   uvicorn relay:app --host 0.0.0.0 --port 8090
Deploy:        any host that terminates WSS on 443 (Fly.io, Render, Railway).
"""

from __future__ import annotations

import json
import os
import time
from contextlib import suppress

from fastapi import FastAPI, WebSocket
from fastapi.responses import JSONResponse

RELAY_TOKEN = os.environ.get("RELAY_TOKEN", "").strip()

app = FastAPI()

receivers: set[WebSocket] = set()   # laptops listening on /recv
_stats = {"frames_in": 0, "frames_out": 0, "senders": 0, "last_ts": 0.0}


def _authorized(ws: WebSocket) -> bool:
    """True if no token is configured, or the client passed the matching one."""
    if not RELAY_TOKEN:
        return True
    return ws.query_params.get("token", "") == RELAY_TOKEN


def _frame_from(message: dict) -> bytes | None:
    """A WebSocket message -> 4 LC2 bytes. Binary is the real path; JSON text is a
    debug aid, the same shape the local server accepts."""
    data = message.get("bytes")
    if data is not None:
        return bytes(data[:4]) if len(data) >= 4 else None
    text = message.get("text")
    if text:
        with suppress(Exception):
            o = json.loads(text)
            return bytes([
                int(o.get("event", 0)) & 0xFF,
                int(o.get("mask", 0)) & 0xFF,
                int(o.get("intensity", 192)) & 0xFF,
                int(o.get("seq", 0)) & 0xFF,
            ])
    return None


async def _broadcast(frame: bytes) -> None:
    """Forward one frame to every connected receiver, dropping dead sockets."""
    dead = []
    for r in receivers:
        try:
            await r.send_bytes(frame)
        except Exception:
            dead.append(r)
    for d in dead:
        receivers.discard(d)
    _stats["frames_out"] += len(receivers)


@app.websocket("/send")
async def send(ws: WebSocket) -> None:
    """The phone. Each inbound frame is forwarded to all receivers."""
    await ws.accept()
    if not _authorized(ws):
        await ws.close(code=1008)
        return
    _stats["senders"] += 1
    print(f"[relay] sender connected ({_stats['senders']} total so far)")
    try:
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            frame = _frame_from(message)
            if frame is not None:
                _stats["frames_in"] += 1
                _stats["last_ts"] = time.time()
                await _broadcast(frame)
    finally:
        print("[relay] sender disconnected")


@app.websocket("/recv")
async def recv(ws: WebSocket) -> None:
    """The laptop. Joins the receiver pool and is fed every forwarded frame."""
    await ws.accept()
    if not _authorized(ws):
        await ws.close(code=1008)
        return
    receivers.add(ws)
    print(f"[relay] receiver connected ({len(receivers)} total)")
    try:
        while True:
            # Receivers do not send; this just blocks until they disconnect.
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
    finally:
        receivers.discard(ws)
        print(f"[relay] receiver disconnected ({len(receivers)} total)")


@app.get("/health")
async def health() -> JSONResponse:
    age = None if _stats["last_ts"] == 0 else round(time.time() - _stats["last_ts"], 2)
    return JSONResponse({
        "receivers": len(receivers),
        "frames_in": _stats["frames_in"],
        "frames_out": _stats["frames_out"],
        "last_frame_age_s": age,
        "token_required": bool(RELAY_TOKEN),
    })


@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse({"service": "citrus-squad belt relay", "send": "/send", "recv": "/recv"})


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "8090"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")
