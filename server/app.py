"""Citrus Squad belt bridge server.

Accepts the phone's LC2 cue stream over a WebSocket and forwards each cue to the
Arduino over one long-lived USB serial connection. The phone keeps doing all the
arbitration and the 100 ms heartbeat; this process is a thin, low-latency
forwarder plus a health dashboard.

This is the no-ESP32 / no-Wi-Fi path: the laptop hosts the link and tethers to
the Arduino over USB. The firmware it drives is `server/arduino/belt/belt.ino`, which
reads ONE newline-terminated word per cue:
  forward | stop | left | right | rotate_left | rotate_right | u_turn | idle
Each word latches a continuous pulse pattern that runs until the next command, so
`idle` is what stops the belt. This server translates each LC2 cue to a word (see
`lc2_to_command`), writes only when the command CHANGES (so the heartbeat does not
re-latch the same pattern), and synthesizes `idle` if the link goes silent.

Wire in:  4 raw LC2 bytes per packet            ->  event, mask, intensity, seq
          over UDP (the phone's real link) or a WebSocket frame (test client / debug)
Wire out: 1 newline-terminated word per change  ->  b"left\\n" / b"stop\\n" / b"idle\\n" / ...

Run:  uvicorn app:app --host 0.0.0.0 --port 8080
      (or `python app.py`, which starts uvicorn for you)

Config via env:
  SERIAL_PORT   serial device, e.g. /dev/tty.usbmodem1101. Unset = auto-detect, then mock.
  SERIAL_BAUD   default 9600 (matches Serial.begin(9600) in belt.ino)
  PORT          HTTP/WebSocket port, default 8080
  UDP_PORT      UDP port the phone sends LC2 to, default 9999 (matches iOS espPort)
  WARMUP_S      seconds to wait after opening serial, for the Arduino auto-reset, default 2.0
  SILENCE_TIMEOUT_S  send `idle` if no cue arrives within this, default 0.5

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

SERIAL_BAUD = int(os.environ.get("SERIAL_BAUD", "9600"))
HTTP_PORT = int(os.environ.get("PORT", "8080"))
# UDP port the phone's LC2Transmitter sends to. Matches the iOS default `espPort` (9999),
# so the operator only has to point the belt host at this laptop's IP.
UDP_PORT = int(os.environ.get("UDP_PORT", "9999"))
WARMUP_S = float(os.environ.get("WARMUP_S", "2.0"))
# The firmware pulses continuously until told otherwise, so if the phone link goes silent
# we must send `idle` ourselves or the belt buzzes forever. Mirrors the 500 ms silence-to-
# quiet rule in docs/03. Slightly longer than two 10 Hz heartbeats so a single dropped
# packet does not blip the belt off.
SILENCE_TIMEOUT_S = float(os.environ.get("SILENCE_TIMEOUT_S", "0.5"))

# LC2 event codes (docs/03-protocol.md).
EV_IDLE = 0x00
EV_VISION = 0x10        # vision-danger
EV_TURN_SLIGHT = 0x20
EV_TURN_NOW = 0x21
EV_TURN_AROUND = 0x22
EV_ARRIVED = 0x23
EV_FORWARD = 0x24       # on-course / proceed straight
EV_OBSTACLE = 0x40      # obstacle-near (LiDAR)

# Quadrant mask bits, cardinal layout (matches belt.ino and the iOS QuadrantMask).
MASK_FRONT = 0x01
MASK_LEFT = 0x02
MASK_RIGHT = 0x04
MASK_BACK = 0x08

# Synthesized when the link goes silent, to quiet the belt.
IDLE_LC2 = bytes([EV_IDLE, 0, 0, 0])


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


def lc2_to_command(lc2: bytes) -> bytes:
    """Translate a 4-byte LC2 cue to the command belt.ino understands.

    The belt fires exactly the motors the phone lit. The cue's quadrant mask (byte 1) is the
    same per-motor bitfield the phone's belt view draws (bit0 Front, bit1 Left, bit2 Right,
    bit3 Back), so we pass it straight through as `m<bits>` and the firmware pulses precisely
    those motors. This is the finite per-servo control: a left-side obstacle taps the left
    motor only, not all four. Intensity and the event's tap-pattern flavor do not survive to
    the Arduino path; the ESP32 path keeps the full LC2 frame.

      - idle (0x00) or empty mask  -> b"idle\\n"   (stops the belt; must be sent)
      - any cue with a mask        -> b"m<bits>\\n" (fire exactly those quadrants)

    The firmware still accepts the named words (forward/stop/left/right/rotate_*/u_turn) for
    manual and dashboard testing; the live cue path uses the mask so it mirrors the display.
    """
    event, mask = lc2[0], lc2[1]
    if event == EV_IDLE or mask == 0:
        return b"idle\n"
    return f"m{mask}\n".encode()


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
        # Where the last packet came from ("ip:port" for UDP, "ws" for the WebSocket path).
        self.last_src = ""
        # Last command actually written, so a repeated cue (the 10 Hz heartbeat restages
        # the same one) is not re-sent and the firmware's one-shot pattern fires once.
        self.last_cmd: bytes | None = None

    def submit(self, lc2: bytes) -> None:
        self.frames_in += 1
        self.last_frame_ts = time.time()
        self.last_lc2 = lc2
        if self.latest.full():
            with suppress(asyncio.QueueEmpty):
                self.latest.get_nowait()
        with suppress(asyncio.QueueFull):
            self.latest.put_nowait(lc2)

    def next_command(self, lc2: bytes) -> bytes | None:
        """Map a cue to its command, suppressing repeats so the firmware's continuous
        pulse is not re-latched every heartbeat. Returns None when unchanged."""
        cmd = lc2_to_command(lc2)
        if cmd == self.last_cmd:
            return None
        self.last_cmd = cmd
        return cmd

    async def _await_cue(self) -> bytes:
        """The next cue, or a synthesized idle if the link falls silent past the timeout."""
        try:
            return await asyncio.wait_for(self.latest.get(), timeout=SILENCE_TIMEOUT_S)
        except asyncio.TimeoutError:
            return IDLE_LC2

    async def writer(self) -> None:
        if self.mock:
            print(f"[serial] MOCK mode (no Arduino). Set SERIAL_PORT to a real device. baud={SERIAL_BAUD}")
            while True:
                cmd = self.next_command(await self._await_cue())
                if cmd is None:
                    continue
                self.frames_out += 1
                print(f"[mock-serial] -> {cmd.decode().strip()}")
            return

        backoff = 1.0
        while True:
            try:
                ser = aioserial.AioSerial(port=self.port, baudrate=SERIAL_BAUD)
                print(f"[serial] opened {self.port} @ {SERIAL_BAUD}; warming up {WARMUP_S}s for Arduino auto-reset")
                await asyncio.sleep(WARMUP_S)  # the Arduino reboots when the port opens
                self.serial_open = True
                self.last_cmd = None  # fresh link: do not assume the board's prior state
                backoff = 1.0
                while True:
                    cmd = self.next_command(await self._await_cue())
                    if cmd is None:
                        continue
                    await ser.write_async(cmd)
                    self.frames_out += 1
            except Exception as exc:  # cable yanked, device gone, etc.
                self.serial_open = False
                print(f"[serial] error: {exc!r}; reconnecting in {backoff:.0f}s")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 10.0)


hub = Hub()


class LC2DatagramProtocol(asyncio.DatagramProtocol):
    """Receives the phone's raw 4-byte LC2 packets over UDP and feeds the same hub the
    WebSocket path uses. This is the real phone link: the iOS `LC2Transmitter` sends UDP
    at 10 Hz to the configured host:port, so the operator just points the belt host at
    this laptop. The WebSocket `/belt` stays for the stand-in test client and debugging."""

    def datagram_received(self, data: bytes, addr) -> None:
        if len(data) >= 4:
            hub.last_src = f"{addr[0]}:{addr[1]}"
            hub.submit(bytes(data[:4]))


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(hub.writer())
    loop = asyncio.get_running_loop()
    udp_transport = None
    try:
        udp_transport, _ = await loop.create_datagram_endpoint(
            LC2DatagramProtocol, local_addr=("0.0.0.0", UDP_PORT))
        print(f"[udp] listening for phone LC2 packets on UDP {UDP_PORT}")
    except Exception as exc:
        print(f"[udp] could not bind UDP {UDP_PORT}: {exc!r} (WebSocket path still works)")
    yield
    if udp_transport is not None:
        udp_transport.close()
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
                hub.last_src = "ws"
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
        "last_cmd": hub.last_cmd.decode().strip() if hub.last_cmd else None,
        "udp_port": UDP_PORT,
        "last_src": hub.last_src or None,
    })


@app.get("/test")
async def test(event: int = 0x21, mask: int = 0x04, intensity: int = 192, seq: int = 0):
    """Fire one cue straight at the belt without the phone. B1/B2 check.
    Default is turn-now on the Right quadrant. Try /test?event=16&mask=6 for a hazard."""
    lc2 = bytes([event & 0xFF, mask & 0xFF, intensity & 0xFF, seq & 0xFF])
    hub.submit(lc2)
    return {"sent_lc2_hex": lc2.hex(" "), "command": lc2_to_command(lc2).decode().strip()}


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
 <button onclick="fire(0x21,0x02)">left</button>
 <button onclick="fire(0x21,0x04)">right</button>
 <button onclick="fire(0x20,0x01)">forward</button>
 <button onclick="fire(0x22,0x06)">u_turn</button>
 <button onclick="fire(0x10,0x06)">stop (hazard)</button>
 <button onclick="fire(0x00,0x00)">idle</button>
</p>
<script>
 const F=['mock','port','serial_open','ws_clients','frames_in','frames_out','last_frame_age_s','last_lc2_hex','last_cmd'];
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
