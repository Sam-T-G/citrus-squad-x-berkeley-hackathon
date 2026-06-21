# 15 — Belt server bridge plan (Arduino Uno + laptop server)

The ESP32 is not working, so the belt link pivots off Wi-Fi-to-microcontroller and onto a wired path: the phone talks to a low-latency server on a laptop, and the laptop drives an Arduino Uno over USB serial. This plan scaffolds that pivot and the research behind the choices. Status: proposal, not yet built. Read `STATUS.md` and `docs/03-protocol.md` first.

## Why this is a small change, not a rewrite

The phone already does the hard part. It arbitrates safety over direction and emits one 4-byte LC2 cue per 100 ms heartbeat (event, mask, intensity, sequence), per `docs/03-protocol.md` and `docs/12` §4. None of that changes. The only things that change are the last two hops:

```
BEFORE:  Phone --UDP (LC2, 4 bytes)--> ESP32 (Wi-Fi) --PWM--> 4 servos
AFTER:   Phone --WebSocket (LC2)--> Laptop server --USB serial--> Arduino Uno --PWM--> 4 servos
```

The LC2 contract survives end to end. The Uno firmware is the same logic the ESP32 firmware was going to run (parse event + mask + intensity, render the tap pattern, fall quiet after 500 ms of silence), just reading from `Serial` instead of a UDP socket. So the change set is three localized pieces:

1. **Phone:** swap the transmitter's UDP send for a WebSocket client. Keep `stage()` and the 100 ms heartbeat. Put it behind a `BeltTransport` protocol so UDP and WebSocket are swappable.
2. **Laptop server (new):** accept the phone's WebSocket, forward each LC2 frame to the Uno over one long-lived serial connection, expose a tiny health dashboard.
3. **Arduino Uno firmware:** read framed LC2 over serial at 115200, drive four servos with the pattern vocabulary, go quiet on silence.

This pivot is arguably more reliable than the ESP32 path: it removes the flaky microcontroller-over-Wi-Fi hop and replaces it with a wired USB link. Only one wireless hop remains (phone to laptop), and the laptop is on the demo table anyway.

## Transport decision: WebSocket, with POST as the simple fallback

Recommended: **WebSocket** (iOS `URLSessionWebSocketTask` to a FastAPI WebSocket endpoint).

- Persistent connection. No per-message TCP/HTTP handshake, which a 10 Hz stream of repeated POSTs pays every time unless you force keep-alive.
- Low protocol overhead for small frequent frames, which is exactly the 4-byte heartbeat.
- Bidirectional. The server can push health back to the phone, which drives the link-alive indicator the operator watches. POST cannot do this cleanly.
- On a local network the raw latency win over POST is modest (about 10 to 20 percent), so the real reasons are the persistent connection and the bidirectional health channel, not speed alone.

Mandatory regardless of transport: **set `TCP_NODELAY` (disable Nagle's algorithm)** on the socket. Without it, small frames can be batched and delayed by tens of milliseconds. Keep frames tiny and turn off any compression.

Payload on the wire: send the **raw 4 LC2 bytes as a binary WebSocket frame**. It is identical to the existing wire format and the server forwards it to serial with almost no translation. Offer a JSON mode (`{event, mask, intensity, seq}`) only as a debug aid.

If the team wants POST for simplicity: HTTP/1.1 with keep-alive works for 10 Hz, but you lose the server-to-phone health channel and add per-request overhead. Treat it as the fallback, not the default.

Rejected options and why:

- **MQTT broker.** Adds a broker process and queueing latency for no benefit at this scale.
- **Firmata (StandardFirmata + pyfirmata / johnny-five).** Lets the laptop drive the Uno pins with no custom firmware, which is tempting, but it makes the **host** own pattern timing. Our tap patterns are timed sequences that must stay deterministic, so the Uno should own them the way the ESP32 was going to. Keep Firmata only as a 30-second "is the wiring alive" smoke test.

## Server stack: FastAPI + uvicorn (uvloop), one long-lived serial

Recommended: **Python, FastAPI on uvicorn with uvloop.**

- Reuses the team's existing Python (Cole's `cv/`), so no new toolchain.
- uvloop makes asyncio 2 to 4 times faster, which is plenty of headroom for a 10 Hz forwarder.
- FastAPI WebSocket support is a few lines.

Serial handling, where the care goes:

- **Open the serial port once at startup and never reopen it.** Reopening resets the Uno (see the auto-reset gotcha below). One connection for the whole demo.
- **Keep serial writes off the event loop.** Each write is 4 to 6 bytes (sub-millisecond), but do it through `aioserial` or a dedicated writer task draining an `asyncio.Queue`, not a naive blocking call in the request path. The older `pyserial-asyncio` has known event-loop-blocking issues; `aioserial` or a queue-plus-executor avoids them.
- **Latest-wins queue.** The forwarder only ever needs the most recent cue. If frames back up, drop stale ones and send the newest, matching the heartbeat semantics.

Equal-quality alternative: **Node.js with `serialport` + `ws`.** `serialport` is very mature. Pick Python only to reuse the team's stack; Node is a fine choice if whoever owns the server is faster in it.

Suggested owner: **Josh.** His `web-app` branch is currently empty, and a small Python WebSocket-to-serial server with a status page is squarely a web/server task with a clear, self-contained deliverable.

## Arduino Uno specifics (the gotchas that bite)

- **DTR auto-reset.** Opening the USB serial port pulses the Uno's reset line and triggers a 1 to 2 second bootloader delay. Mitigation in software: open the port once and keep it open; add a 2 second warmup after connect before trusting the link. Optional hardware fix: cut the `RST EN` pads, or put a 10 µF capacitor between `RST` and `5V`, to disable auto-reset entirely.
- **Baud.** 115200-8-N-1. The Uno bootloader expects 115200.
- **Servo + Serial coexist.** On the classic Uno the `Servo` library drives up to 12 servos on Timer1 and works fine alongside `Serial` at 115200. (The timer conflict warnings you find online are for the UNO WiFi Rev2, not the classic Uno.)
- **Framing.** Serial is a byte stream with no packet boundaries, so a single dropped byte desyncs a raw 4-byte cadence. Wrap each cue in a tiny frame with a sync byte and a checksum:
  ```
  [0xA5][event][mask][intensity][seq][checksum]   // 6 bytes; checksum = event^mask^intensity^seq
  ```
  The Uno seeks `0xA5`, reads the next five bytes, validates the checksum, and drops bad frames (a dropped frame just means the next heartbeat resends). COBS framing is the robust upgrade if you see corruption, but the sync-byte-plus-checksum frame is enough for a clean USB link.
- **Servo power.** Same rule as the ESP32 plan: four servos draw too much for the Uno's 5V pin. Run the servos off a separate 5V rail with a bulk capacitor, share ground with the Uno, and keep only the signal lines on the Uno PWM pins. The Uno itself powers from USB.

## Latency budget

| Hop | Estimate |
|---|---|
| Phone to laptop, WebSocket over local Wi-Fi or hotspot | ~5 to 30 ms (Wi-Fi dependent) |
| Server processing + queue | < 1 ms |
| USB serial, 6 bytes at 115200 + USB scheduling | ~1 to 3 ms |
| Uno parse + servo command | < 2 ms |
| **Total emit to felt tap** | **well under the 250 ms target** |

The wired serial leg is far more deterministic than the ESP32 Wi-Fi link it replaces. The only remaining latency and reliability variable is the phone-to-laptop Wi-Fi, the same variable as before but now the single wireless hop. Mitigate with the laptop hotspot or a dedicated travel-router SSID, plus `TCP_NODELAY`.

## Reliability and demo hardening

- One long-lived WebSocket and one long-lived serial connection. The phone heartbeats at 10 Hz, the server forwards the latest cue, and the Uno falls quiet after 500 ms of silence. The fail-safe contract is unchanged: silence beats a stale cue.
- New single points of failure: the laptop, the phone-to-laptop link, and the USB cable (unplugging it resets the Uno). Mitigations: keep the laptop awake and plugged in, secure the USB cable with tape or a strain relief, have the server reconnect serial with the 2 second warmup, and show a small dashboard (last packet, serial state, WebSocket state) so the operator sees health at a glance.
- Fully wired nuclear option for a hostile Wi-Fi room: tether the phone to the laptop over USB (Personal Hotspot over USB gives the laptop a network interface to the phone), then laptop to Uno over USB. Zero RF in the whole chain. Keep this in the back pocket for the venue.

## Build order

Each step is independently testable and de-risks the next.

- **B0 — Servo + Uno alive.** Uno firmware twitches one servo on a hardcoded byte typed into the Arduino IDE serial monitor. Proves wiring and servo power.
- **B1 — Server to Uno.** The laptop server opens serial once and sends a test frame on an HTTP route or keypress. Belt twitches. Proves the server-to-Uno path and the open-once discipline.
- **B2 — WebSocket to serial.** Server WebSocket endpoint; a `wscat` test client sends a frame and the belt fires. Proves the WebSocket-to-serial bridge with no phone involved.
- **B3 — Phone end to end.** Phone `WebSocketBeltTransport` replaces UDP; the existing "Send test cue" button fires over WebSocket and the belt reacts. This is the M0-equivalent: the link is proven before routing.
- **B4 — Full heartbeat.** The 10 Hz heartbeat and the safety-over-direction arbitration run over WebSocket. Walk the bench, cues fire on the right side, and a 500 ms link cut goes quiet.
- **B5 — Harden.** Dashboard, serial reconnect with warmup, hotspot config, and a measured emit-to-felt latency number for the pitch.

## Scaffold: code skeletons

### Arduino Uno firmware (sketch)

```cpp
#include <Servo.h>

const uint8_t PINS[4] = {9, 10, 11, 6};   // Far Left, Left, Right, Far Right
Servo servos[4];
const int NEUTRAL = 0, TAP = 30;          // degrees
unsigned long lastFrameMs = 0;
const unsigned long SILENCE_TIMEOUT = 500;

void setup() {
  Serial.begin(115200);
  for (int i = 0; i < 4; i++) { servos[i].attach(PINS[i]); servos[i].write(NEUTRAL); }
}

void loop() {
  // Seek the 0xA5 sync byte, then read a 5-byte body: event, mask, intensity, seq, checksum.
  if (Serial.available() && Serial.read() == 0xA5) {
    uint8_t b[5];
    if (readN(b, 5)) {
      uint8_t sum = b[0] ^ b[1] ^ b[2] ^ b[3];
      if (sum == b[4]) { render(b[0], b[1], b[2]); lastFrameMs = millis(); }
    }
  }
  if (millis() - lastFrameMs > SILENCE_TIMEOUT) goQuiet();
  serviceActivePattern();   // non-blocking pattern stepper
}

// render() maps event -> pattern (single / triple / sweep / tap-train) and mask -> which servos.
// Keep it non-blocking: set targets + timers, step them in serviceActivePattern(), never delay().
```

### Laptop server (FastAPI + aioserial)

```python
import asyncio, aioserial
from fastapi import FastAPI, WebSocket

app = FastAPI()
ser = aioserial.AioSerial(port="/dev/tty.usbmodemXXXX", baudrate=115200)  # open ONCE
latest = asyncio.Queue(maxsize=1)  # latest-wins

async def serial_writer():
    while True:
        frame = await latest.get()                      # 4 LC2 bytes
        body = bytes([frame[0]^frame[1]^frame[2]^frame[3]])
        await ser.write_async(bytes([0xA5]) + frame + body)  # 0xA5 + 4 + checksum

@app.on_event("startup")
async def boot():
    await asyncio.sleep(2)                  # Uno auto-reset warmup
    asyncio.create_task(serial_writer())

@app.websocket("/belt")
async def belt(ws: WebSocket):
    await ws.accept()
    ws._transport.get_extra_info("socket").setsockopt(  # TCP_NODELAY
        __import__("socket").IPPROTO_TCP, __import__("socket").TCP_NODELAY, 1)
    while True:
        frame = await ws.receive_bytes()    # 4 LC2 bytes from the phone
        if latest.full(): latest.get_nowait()
        latest.put_nowait(frame)

# Run: uvicorn server:app --host 0.0.0.0 --port 8080 --loop uvloop
# /health route + a tiny HTML dashboard (last frame, serial open?, ws connected?) goes here too.
```

### Phone transport seam (Swift)

```swift
protocol BeltTransport: Sendable {            // UDP and WebSocket both conform
    func start() async
    func send(_ frame: Data) async            // the 4 LC2 bytes
    func stop() async
}

actor WebSocketBeltTransport: BeltTransport {
    private var task: URLSessionWebSocketTask?
    func start() async {
        var req = URLRequest(url: URL(string: "ws://LAPTOP_IP:8080/belt")!)
        // URLSession sets TCP_NODELAY for WebSocket tasks; keep frames tiny.
        task = URLSession.shared.webSocketTask(with: req); task?.resume()
    }
    func send(_ frame: Data) async { try? await task?.send(.data(frame)) }
    func stop() async { task?.cancel(with: .normalClosure, reason: nil) }
}
```

The existing `LC2Transmitter` actor keeps its `stage()` and 100 ms heartbeat; it just calls `transport.send(packet.encoded())` instead of writing to the UDP socket. Make the host and port operator-editable in the diagnostics screen the way the ESP32 host already is.

## Coordination with existing work

- There is already an `arduino` branch with a root `belt.ino`, plus `firmware/citrus_squad_belt/` from the ESP32 plan. This plan converges them onto the serial-driven Uno path. The hardware owner (Angelo) should own the Uno firmware; this doc proposes the framing contract and the pattern mapping rather than rewriting their sketch.
- The phone `BeltTransport` swap is the Swift lane's work.
- The laptop server is a new, self-contained lane; suggested owner Josh.
- `docs/03-protocol.md` and `docs/01-architecture.md` still describe the UDP-to-ESP32 transport. They need a follow-up pass to note that LC2 now also runs over WebSocket-to-serial with the 6-byte serial framing. The 4-byte semantics are unchanged. Do that pass once the team confirms this pivot, to avoid editing those docs under another agent mid-build.

## Sources

- [WebSockets vs HTTP, Postman](https://blog.postman.com/websockets-vs-http-key-differences-explained/) and [are WebSockets faster than AJAX (local-network latency), Peterbe](https://www.peterbe.com/plog/are-websockets-faster-than-ajax)
- [TCP_NODELAY for websockets, aiohttp issue](https://github.com/aio-libs/aiohttp/issues/664)
- [FastAPI WebSockets](https://fastapi.tiangolo.com/advanced/websockets/) and [Uvicorn](https://www.uvicorn.org/)
- [Arduino automatic reset, Quentin Santos](https://qsantos.fr/2025/05/01/arduino-automatic-reset/) and [disable auto-reset, Arduino Forum](https://forum.arduino.cc/t/disable-auto-reset-by-serial-connection/28248)
- [aioserial](https://pypi.org/project/aioserial/), [pyserial-asyncio](https://pypi.org/project/pyserial-asyncio/), and [solving pyserial-asyncio event-loop blocking, Home Assistant](https://developers.home-assistant.io/blog/2026/01/05/pyserial-asyncio-fast/)
- [Firmata protocol](https://github.com/firmata/protocol) and [pyFirmata](https://pyfirmata.readthedocs.io/en/latest/pyfirmata.html)
