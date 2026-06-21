"""
Real-time CV dashboard -- webcam source, browser UI.

Starts a local server on port 8001 and serves:
  GET /            -- the dashboard page
  GET /video_feed  -- MJPEG stream of annotated frames
  WS  /ws/detections  -- JSON detection stream (~10 fps)

Usage:
    python -m cv.dashboard          # built-in camera
    python -m cv.dashboard 1        # external camera index

Open http://localhost:8001 after starting.
macOS: grant camera access to Terminal.app (System Settings > Privacy > Camera).
"""

from __future__ import annotations

import asyncio
import colorsys
import hashlib
import json
import sys
import threading
import time

import cv2
import numpy as np
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, StreamingResponse

from .pipeline import CVPipeline

# ── shared state ──────────────────────────────────────────────────────────────

_lock = threading.Lock()
_frame_jpeg: bytes = b""
_detections: list[dict] = []

SYNTHETIC_DEPTH_M = 2.0

# ── color helpers ─────────────────────────────────────────────────────────────


def _label_color_rgb(label: str) -> tuple[int, int, int]:
    """Deterministic, visually distinct color per label."""
    h = int(hashlib.md5(label.encode()).hexdigest()[:8], 16) % 360
    r, g, b = colorsys.hsv_to_rgb(h / 360.0, 0.78, 0.92)
    return int(r * 255), int(g * 255), int(b * 255)


def _hex(label: str) -> str:
    r, g, b = _label_color_rgb(label)
    return f"#{r:02x}{g:02x}{b:02x}"


def _bgr(label: str) -> tuple[int, int, int]:
    r, g, b = _label_color_rgb(label)
    return b, g, r


# ── capture thread ────────────────────────────────────────────────────────────


def _capture_loop(camera_index: int) -> None:
    global _frame_jpeg, _detections

    pipeline = CVPipeline()
    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        print(f"ERROR: Cannot open camera {camera_index}", file=sys.stderr)
        return

    print(f"Camera {camera_index} open. Dashboard: http://localhost:8001")

    while True:
        ok, frame = cap.read()
        if not ok:
            time.sleep(0.033)
            continue

        h, w = frame.shape[:2]
        depth_map = np.full((h, w), SYNTHETIC_DEPTH_M, dtype=np.float32)
        detections = pipeline.process(frame, depth_map)

        vis = frame.copy()
        for det in detections:
            x1, y1, x2, y2 = det.bbox_px
            bgr = _bgr(det.label)
            cv2.rectangle(vis, (x1, y1), (x2, y2), bgr, 2)
            depth_str = f"{det.depth_min_m:.1f}m" if det.depth_min_m is not None else "?"
            text = f"{det.label}  {det.confidence:.0%}  {depth_str}"
            cv2.putText(
                vis, text, (x1 + 4, max(y1 + 18, 18)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.52, bgr, 2, cv2.LINE_AA,
            )

        _, jpeg = cv2.imencode(".jpg", vis, [cv2.IMWRITE_JPEG_QUALITY, 78])
        payload = sorted(
            [{**d.to_dict(), "color": _hex(d.label)} for d in detections],
            key=lambda x: x["depth_min_m"] if x["depth_min_m"] is not None else 99.0,
        )

        with _lock:
            _frame_jpeg = jpeg.tobytes()
            _detections = payload


# ── FastAPI ───────────────────────────────────────────────────────────────────

app = FastAPI()


@app.get("/video_feed")
async def video_feed() -> StreamingResponse:
    async def _gen():
        while True:
            with _lock:
                jpeg = _frame_jpeg
            if jpeg:
                yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n"
            await asyncio.sleep(0.033)

    return StreamingResponse(_gen(), media_type="multipart/x-mixed-replace; boundary=frame")


@app.websocket("/ws/detections")
async def detections_ws(ws: WebSocket) -> None:
    await ws.accept()
    try:
        while True:
            with _lock:
                payload = json.dumps(_detections)
            await ws.send_text(payload)
            await asyncio.sleep(0.1)
    except (WebSocketDisconnect, Exception):
        pass


@app.get("/")
def index() -> HTMLResponse:
    return HTMLResponse(_HTML)


# ── entrypoint ────────────────────────────────────────────────────────────────


def run(camera_index: int = 0) -> None:
    t = threading.Thread(target=_capture_loop, args=(camera_index,), daemon=True)
    t.start()
    uvicorn.run(app, host="0.0.0.0", port=8001, log_level="warning")


if __name__ == "__main__":
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    run(idx)


# ── dashboard HTML ────────────────────────────────────────────────────────────

_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WAND -- CV Dashboard</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:      #09090f;
      --surface: #0f0f18;
      --border:  #1c1c2a;
      --text:    #dde0ee;
      --muted:   #525870;
    }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', ui-monospace, monospace;
      display: flex;
      flex-direction: column;
      height: 100vh;
      overflow: hidden;
    }

    /* top bar */
    #topbar {
      flex: 0 0 44px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 0 20px;
      border-bottom: 1px solid var(--border);
      background: var(--surface);
    }
    #topbar .brand  { font-size: 13px; font-weight: 700; letter-spacing: 0.06em; }
    #topbar .sep    { color: var(--border); }
    #topbar .sub    { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.12em; }
    .live {
      margin-left: auto;
      display: flex; align-items: center; gap: 6px;
      font-size: 10px; color: #30d158; text-transform: uppercase; letter-spacing: 0.1em;
    }
    .live-dot {
      width: 7px; height: 7px; border-radius: 50%; background: #30d158;
      animation: blink 1.8s ease-in-out infinite;
    }
    @keyframes blink { 0%,100% { opacity:1 } 50% { opacity:0.2 } }

    /* main split */
    #main { flex: 1; display: flex; min-height: 0; }

    /* camera panel */
    #cam {
      flex: 1; display: flex; flex-direction: column;
      padding: 14px; gap: 8px; min-width: 0;
    }
    #cam-label { font-size: 9px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.12em; }
    #vid-wrap {
      flex: 1; border-radius: 10px; overflow: hidden;
      background: #000; border: 1px solid var(--border);
      display: flex; align-items: center; justify-content: center;
    }
    #vid { width: 100%; height: 100%; object-fit: contain; display: block; }

    /* sidebar */
    #sidebar {
      flex: 0 0 340px; border-left: 1px solid var(--border);
      display: flex; flex-direction: column; overflow: hidden;
    }

    #sb-head {
      padding: 14px 16px 10px;
      display: flex; align-items: baseline; gap: 7px;
      border-bottom: 1px solid var(--border);
    }
    #obj-count { font-size: 24px; font-weight: 700; }
    #sb-head .lbl { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.1em; }

    #det-list {
      flex: 1; overflow-y: auto;
      padding: 10px 12px 12px;
      display: flex; flex-direction: column; gap: 9px;
    }
    #det-list::-webkit-scrollbar { width: 3px; }
    #det-list::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

    /* card */
    .card {
      border-radius: 9px;
      border: 1px solid var(--border);
      border-left: 3px solid var(--c);
      background: var(--surface);
      padding: 11px 13px;
    }
    .card-top {
      display: flex; align-items: center;
      justify-content: space-between;
      margin-bottom: 11px;
    }
    .card-label {
      font-size: 13px; font-weight: 600;
      color: var(--c); text-transform: capitalize;
    }
    .badge {
      font-size: 9px; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.1em;
      padding: 3px 7px; border-radius: 4px;
      background: var(--pc); color: #09090f;
    }

    .metrics { display: flex; flex-direction: column; gap: 8px; }
    .metric  { display: flex; flex-direction: column; gap: 4px; }
    .mhdr {
      display: flex; justify-content: space-between;
      font-size: 9px; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.09em;
    }
    .mhdr .val { color: var(--text); }

    .bar { height: 4px; background: var(--border); border-radius: 2px; overflow: hidden; }
    .bar-fill { height: 100%; border-radius: 2px; transition: width 0.12s ease; }

    /* position track */
    .pos-labels {
      display: flex; justify-content: space-between;
      font-size: 8px; color: var(--muted); margin-top: 1px;
    }
    .pos-track { position: relative; height: 4px; background: var(--border); border-radius: 2px; margin-top: 3px; }
    .pos-dot {
      position: absolute;
      width: 9px; height: 9px; border-radius: 50%;
      background: var(--c);
      top: 50%; transform: translate(-50%, -50%);
      transition: left 0.12s ease;
      box-shadow: 0 0 6px var(--c);
    }

    /* empty state */
    .empty {
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; height: 100%;
      gap: 6px; color: var(--muted); font-size: 12px;
    }
    .empty .icon { font-size: 26px; opacity: 0.25; }
  </style>
</head>
<body>

<div id="topbar">
  <span class="brand">WAND</span>
  <span class="sep">/</span>
  <span class="sub">CV Pipeline Monitor</span>
  <div class="live"><div class="live-dot"></div>Live</div>
</div>

<div id="main">
  <div id="cam">
    <div id="cam-label">Camera feed</div>
    <div id="vid-wrap">
      <img id="vid" src="/video_feed" alt="live camera">
    </div>
  </div>

  <div id="sidebar">
    <div id="sb-head">
      <span id="obj-count">0</span>
      <span class="lbl">objects</span>
    </div>
    <div id="det-list">
      <div class="empty"><div class="icon">&#9675;</div><div>No objects detected</div></div>
    </div>
  </div>
</div>

<script>
  const list = document.getElementById('det-list');
  const cnt  = document.getElementById('obj-count');

  function proxInfo(d) {
    if (d === null || d === undefined) return { text: 'N/A',   color: '#525870' };
    if (d < 1.0)  return { text: 'CLOSE', color: '#ff3b3b' };
    if (d < 2.0)  return { text: 'NEAR',  color: '#ff9500' };
    if (d < 3.5)  return { text: 'MID',   color: '#ffd60a' };
    return              { text: 'FAR',   color: '#30d158' };
  }

  function proxPct(d) {
    if (d === null || d === undefined) return 0;
    return Math.max(0, Math.min(100, (1 - d / 6.0) * 100));
  }

  function side(n) {
    if (n < 0.38) return 'left';
    if (n > 0.62) return 'right';
    return 'center';
  }

  function render(dets) {
    cnt.textContent = dets.length;

    if (!dets.length) {
      list.innerHTML = '<div class="empty"><div class="icon">&#9675;</div><div>No objects detected</div></div>';
      return;
    }

    list.innerHTML = dets.map(d => {
      const { text: pt, color: pc } = proxInfo(d.depth_min_m);
      const pp   = proxPct(d.depth_min_m);
      const conf = (d.confidence * 100).toFixed(0);
      const dmin = d.depth_min_m  != null ? d.depth_min_m.toFixed(2)  + ' m' : 'N/A';
      const dmed = d.depth_median_m != null ? d.depth_median_m.toFixed(2) + ' m' : 'N/A';
      const hpct = (d.horizontal_norm * 100).toFixed(1);

      return `
        <div class="card" style="--c:${d.color};--pc:${pc}">
          <div class="card-top">
            <span class="card-label">${d.label}</span>
            <span class="badge">${pt}</span>
          </div>
          <div class="metrics">

            <div class="metric">
              <div class="mhdr"><span>Confidence</span><span class="val">${conf}%</span></div>
              <div class="bar">
                <div class="bar-fill" style="width:${conf}%;background:var(--c)"></div>
              </div>
            </div>

            <div class="metric">
              <div class="mhdr">
                <span>Proximity min</span>
                <span class="val" style="color:${pc}">${dmin}</span>
              </div>
              <div class="bar">
                <div class="bar-fill" style="width:${pp}%;background:${pc}"></div>
              </div>
            </div>

            <div class="metric">
              <div class="mhdr"><span>Depth median</span><span class="val">${dmed}</span></div>
            </div>

            <div class="metric">
              <div class="mhdr"><span>Position</span><span class="val">${side(d.horizontal_norm)}</span></div>
              <div class="pos-labels"><span>L</span><span>R</span></div>
              <div class="pos-track">
                <div class="pos-dot" style="left:${hpct}%"></div>
              </div>
            </div>

          </div>
        </div>`;
    }).join('');
  }

  const ws = new WebSocket(`ws://${location.host}/ws/detections`);
  ws.onmessage = e => render(JSON.parse(e.data));
  ws.onclose   = () => { cnt.textContent = '--'; };
</script>

</body>
</html>"""
