"""Citrus Squad belt bridge server.

Accepts the phone's LC2 cue stream over a WebSocket and forwards each cue to the
Arduino Uno over one long-lived USB serial connection. The phone keeps doing all
the arbitration and the 100 ms heartbeat; this process is a thin, low-latency
forwarder plus a health dashboard.

Wire in:  4 raw LC2 bytes per WebSocket frame  ->  event, mask, intensity, seq
Wire out: 6 framed bytes per serial write       ->  0xA5, event, mask, intensity, seq, checksum

Run:  uvicorn app:app --host 0.0.0.0 --port 8080
      (or `python app.py`, which starts uvicorn for you)

Config via env:
  SERIAL_PORT   serial device, e.g. /dev/tty.usbmodem1101. Unset = auto-detect, then mock.
  SERIAL_BAUD   default 115200 (the Uno bootloader expects this)
  PORT          HTTP/WebSocket port, default 8080
  WARMUP_S      seconds to wait after opening serial, for the Uno auto-reset, default 2.0

See docs/15-belt-server-bridge-plan.md for the why behind every choice here.
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import time
from contextlib import asynccontextmanager, suppress

from fastapi import FastAPI, WebSocket
from fastapi.responses import HTMLResponse, JSONResponse

try:
    import aioserial  # pyserial-asyncio for humans; opens the real port
    from serial.tools import list_ports
except ImportError:  # the app still runs in mock mode without these
    aioserial = None
    list_ports = None

SERIAL_BAUD = int(os.environ.get("SERIAL_BAUD", "115200"))
HTTP_PORT = int(os.environ.get("PORT", "8080"))
WARMUP_S = float(os.environ.get("WARMUP_S", "2.0"))
SYNC_BYTE = 0xA5


def autodetect_port() -> str | None:
    """First USB serial port that looks like an Arduino, or None."""
    env = os.environ.get("SERIAL_PORT", "").strip()
    if env:
        return None if env.lower() == "mock" else env
    if list_ports is None:
        return None
    for p in list_ports.comports():
        name = p.device.lower()
        if any(tag in name for tag in ("usbmodem", "usbserial", "ttyacm", "ttyusb", "wchusb")):
            return p.device
    return None


def serial_frame(lc2: bytes) -> bytes:
    """Wrap the 4 LC2 bytes for the serial link: sync byte + payload + XOR checksum."""
    e, m, i, s = lc2[0], lc2[1], lc2[2], lc2[3]
    return bytes([SYNC_BYTE, e, m, i, s, e ^ m ^ i ^ s])


def parse_inbound(message: dict) -> bytes | None:
    """A WebSocket message -> 4 LC2 bytes, or None if it is not a valid cue.

    Binary frames are the real path (raw LC2). Text frames are a JSON debug aid:
    {"event":33,"mask":4,"intensity":192,"seq":0}.
    """
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


class Hub:
    """Latest-wins forwarder. Only the most recent cue matters, so a backed-up
    queue drops stale frames and sends the newest, matching the heartbeat model."""

    def __init__(self) -> None:
        self.port = autodetect_port()
        self.mock = self.port is None or aioserial is None
        self.latest: asyncio.Queue[bytes] = asyncio.Queue(maxsize=1)
        self.serial_open = False
        self.ws_clients = 0
        self.frames_in = 0
        self.frames_out = 0
        self.last_frame_ts = 0.0
        self.last_lc2 = b""

    def submit(self, lc2: bytes) -> None:
        self.frames_in += 1
        self.last_frame_ts = time.time()
        self.last_lc2 = lc2
        if self.latest.full():
            with suppress(asyncio.QueueEmpty):
                self.latest.get_nowait()
        with suppress(asyncio.QueueFull):
            self.latest.put_nowait(lc2)

    async def writer(self) -> None:
        if self.mock:
            print(f"[serial] MOCK mode (no Arduino). Set SERIAL_PORT to a real device. baud={SERIAL_BAUD}")
            while True:
                lc2 = await self.latest.get()
                self.frames_out += 1
                print(f"[mock-serial] -> {serial_frame(lc2).hex(' ')}")
            return

        backoff = 1.0
        while True:
            try:
                ser = aioserial.AioSerial(port=self.port, baudrate=SERIAL_BAUD)
                print(f"[serial] opened {self.port} @ {SERIAL_BAUD}; warming up {WARMUP_S}s for Uno auto-reset")
                await asyncio.sleep(WARMUP_S)  # the Uno reboots when the port opens
                self.serial_open = True
                backoff = 1.0
                while True:
                    lc2 = await self.latest.get()
                    await ser.write_async(serial_frame(lc2))
                    self.frames_out += 1
            except Exception as exc:  # cable yanked, device gone, etc.
                self.serial_open = False
                print(f"[serial] error: {exc!r}; reconnecting in {backoff:.0f}s")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 10.0)


hub = Hub()


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(hub.writer())
    yield
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task


app = FastAPI(lifespan=lifespan)


def _set_nodelay(ws: WebSocket) -> None:
    """Best-effort TCP_NODELAY. iOS already sets it for WebSocket tasks; this covers
    the server side. Quietly skips if the transport socket is not reachable."""
    with suppress(Exception):
        transport = ws.scope.get("transport") or getattr(ws, "_transport", None)
        sock = transport.get_extra_info("socket") if transport else None
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


@app.websocket("/belt")
async def belt(ws: WebSocket) -> None:
    await ws.accept()
    _set_nodelay(ws)
    hub.ws_clients += 1
    print(f"[ws] client connected ({hub.ws_clients} total)")
    try:
        while True:
            message = await ws.receive()
            if message.get("type") == "websocket.disconnect":
                break
            lc2 = parse_inbound(message)
            if lc2 is not None:
                hub.submit(lc2)
    finally:
        hub.ws_clients = max(0, hub.ws_clients - 1)
        print(f"[ws] client disconnected ({hub.ws_clients} total)")


@app.get("/health")
async def health() -> JSONResponse:
    age = None if hub.last_frame_ts == 0 else round(time.time() - hub.last_frame_ts, 2)
    return JSONResponse({
        "mock": hub.mock,
        "port": hub.port,
        "baud": SERIAL_BAUD,
        "serial_open": hub.serial_open,
        "ws_clients": hub.ws_clients,
        "frames_in": hub.frames_in,
        "frames_out": hub.frames_out,
        "last_frame_age_s": age,
        "last_lc2_hex": hub.last_lc2.hex(" ") if hub.last_lc2 else None,
    })


@app.get("/test")
async def test(event: int = 0x21, mask: int = 0x04, intensity: int = 192, seq: int = 0):
    """Fire one cue straight at the belt without the phone. B1/B2 check.
    Default is turn-now on the Right quadrant. Try /test?event=16&mask=6 for a hazard."""
    lc2 = bytes([event & 0xFF, mask & 0xFF, intensity & 0xFF, seq & 0xFF])
    hub.submit(lc2)
    return {"sent_lc2_hex": lc2.hex(" "), "serial_frame_hex": serial_frame(lc2).hex(" ")}


@app.get("/", response_class=HTMLResponse)
async def dashboard() -> str:
    return DASHBOARD_HTML


DASHBOARD_HTML = """<!doctype html><html><head><meta charset=utf-8>
<title>Citrus Squad belt bridge</title>
<style>
 body{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:560px;margin:40px auto;padding:0 16px}
 h1{font-size:20px} .row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #eee}
 .k{color:#666} .v{font-family:ui-monospace,monospace} .ok{color:#0a7f28} .bad{color:#c0392b}
 button{font:inherit;padding:8px 12px;margin:4px 4px 0 0;cursor:pointer}
</style></head><body>
<h1>Citrus Squad belt bridge</h1>
<div id=board></div>
<p>
 <button onclick="fire(0x20,0x04)">turn-slight R</button>
 <button onclick="fire(0x21,0x08)">turn-now FarR</button>
 <button onclick="fire(0x10,0x06)">hazard center</button>
 <button onclick="fire(0x00,0x00)">idle</button>
</p>
<script>
 const F=['mock','port','serial_open','ws_clients','frames_in','frames_out','last_frame_age_s','last_lc2_hex'];
 async function tick(){
   const h=await (await fetch('/health')).json();
   board.innerHTML=F.map(k=>{
     let v=h[k]; let cls='v';
     if(k==='serial_open') cls='v '+(v?'ok':'bad');
     if(k==='mock'&&v) cls='v bad';
     return `<div class=row><span class=k>${k}</span><span class="${cls}">${v}</span></div>`;
   }).join('');
 }
 function fire(e,m){fetch(`/test?event=${e}&mask=${m}`)}
 tick(); setInterval(tick,500);
</script></body></html>"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=HTTP_PORT, loop="auto", log_level="warning")
