#!/usr/bin/env python3
"""
WAND CV server entrypoint.

Two WebSocket endpoints:
  /frames  — iPhone app streams paired RGB + LiDAR frames (binary protocol)
  /haptics — haptic controller connects here to receive detection JSON

Run:
    python server.py
    # or
    uvicorn server:app --host 0.0.0.0 --port 8000
"""

import json

import uvicorn
from fastapi import WebSocket, WebSocketDisconnect

from cv.detection import DepthFusedDetection
from cv.ingest import app, register_output

# All connected haptic controller clients.
_haptic_clients: set[WebSocket] = set()


@app.websocket("/haptics")
async def haptics_ws(ws: WebSocket) -> None:
    await ws.accept()
    _haptic_clients.add(ws)
    try:
        # Block until disconnect. Absorb any keep-alive pings from the client.
        while True:
            await ws.receive_text()
    except (WebSocketDisconnect, Exception):
        _haptic_clients.discard(ws)


async def _broadcast(detections: list[DepthFusedDetection]) -> None:
    if not detections or not _haptic_clients:
        return

    # Sort by closest depth first so the haptic layer can prioritize
    # the most urgent obstacle without sorting on its end.
    sorted_detections = sorted(
        detections,
        key=lambda d: d.depth_min_m if d.depth_min_m is not None else float("inf"),
    )
    payload = json.dumps([d.to_dict() for d in sorted_detections])

    dead: set[WebSocket] = set()
    for ws in _haptic_clients:
        try:
            await ws.send_text(payload)
        except Exception:
            dead.add(ws)
    _haptic_clients -= dead


register_output(_broadcast)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
