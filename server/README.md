# Belt bridge server

Low-latency forwarder between the phone and the Arduino Uno. The phone sends its LC2 cue stream over a WebSocket; this server forwards each cue to the Uno over one long-lived USB serial connection, and serves a health dashboard. The design and the research behind it are in [`../docs/15-belt-server-bridge-plan.md`](../docs/15-belt-server-bridge-plan.md).

```
Phone --WebSocket (4 LC2 bytes)--> this server --USB serial (6 framed bytes)--> Arduino Uno
```

It runs with no hardware attached (mock mode), so the server can be built and tested before the Uno is wired.

## Setup

```sh
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```sh
python app.py            # or: uvicorn app:app --host 0.0.0.0 --port 8080
```

Open the dashboard at <http://localhost:8080>. It shows the serial state, connected WebSocket clients, and the last frame, and has buttons to fire test cues at the belt.

If no Arduino is found it prints `MOCK mode` and logs every frame instead of writing serial, so the whole WebSocket path is testable on its own.

## Finding the serial port

```sh
python -m serial.tools.list_ports     # lists devices
ls /dev/tty.usbmodem* /dev/tty.usbserial*   # macOS
```

Set it explicitly if auto-detect picks the wrong one:

```sh
SERIAL_PORT=/dev/tty.usbmodem1101 python app.py
```

## Test the path without the phone

- **Server to belt (B1):** with the dashboard open, click a test button, or hit `http://localhost:8080/test?event=33&mask=4` (turn-now, Right). The belt should fire, or in mock mode you see the framed bytes logged.
- **WebSocket to belt (B2 / B4):** run the stand-in phone, which streams a scripted cue sequence at 10 Hz:
  ```sh
  python test_client.py            # server on this machine
  python test_client.py <laptop-ip>
  ```

## Connecting the phone

Point the iOS `WebSocketBeltTransport` at `ws://<laptop-ip>:8080/belt`. Put the laptop and phone on the same network (laptop hotspot or a travel router is best; it gives the link clean airtime). Find the laptop IP with `ipconfig getifaddr en0` on macOS. Allow incoming connections if the firewall prompts.

## Wire format

- **In (WebSocket):** the 4 raw LC2 bytes per frame, `event, mask, intensity, seq`, exactly what the phone already builds. A JSON text frame `{"event":33,"mask":4,"intensity":192,"seq":0}` also works, for debugging.
- **Out (serial):** 6 bytes, `0xA5, event, mask, intensity, seq, checksum`, where `checksum = event ^ mask ^ intensity ^ seq`. The Uno seeks the `0xA5` sync byte, reads the next five, and drops frames whose checksum does not match.

## Config (env vars)

| Var | Default | Meaning |
|---|---|---|
| `SERIAL_PORT` | auto-detect, then mock | serial device, or `mock` to force mock mode |
| `SERIAL_BAUD` | `115200` | the Uno bootloader expects 115200 |
| `PORT` | `8080` | HTTP / WebSocket port |
| `WARMUP_S` | `2.0` | pause after opening serial, for the Uno auto-reset |

## Notes

- The serial port is opened **once** and held for the whole session. Opening it resets the Uno (its DTR auto-reset), so the server never reopens per message; it reconnects with a warmup only if the link drops.
- Latest-wins: only the most recent cue is forwarded, matching the 10 Hz heartbeat. The Uno owns the 500 ms silence-to-quiet fallback, so if the phone stops, the belt goes quiet on its own.
- This server never decides cues. The phone owns all arbitration; this is a forwarder.
