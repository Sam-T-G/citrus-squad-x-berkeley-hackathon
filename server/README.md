# Belt bridge server

Low-latency forwarder between the phone and the Arduino. This is the no-ESP32 / no-Wi-Fi path: the laptop hosts the link and tethers to the Arduino over USB. The phone sends its LC2 cue stream over a WebSocket; this server translates each cue to a single command byte and writes it to the Arduino over one long-lived USB serial connection, and serves a health dashboard. The design and the research behind it are in [`../docs/15-belt-server-bridge-plan.md`](../docs/15-belt-server-bridge-plan.md).

```
Phone --UDP (4 LC2 bytes)--> this server --USB serial (1 command byte)--> Arduino
            (WebSocket /belt also accepted, for the test client and browser debug)
```

The Arduino firmware it drives is [`arduino/belt.ino`](arduino/belt.ino) (Adafruit PCA9685 + a four-pattern state machine), which reads one ASCII byte per cue: `s` stop/hazard, `l` left, `r` right, `f` straight. The server only writes when the command **changes**, so the firmware's one-shot tap patterns are not re-triggered by the phone's 10 Hz heartbeat.

It runs with no hardware attached (mock mode), so the server can be built and tested before the Arduino is wired.

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

If no Arduino is found it prints `MOCK mode` and logs every command instead of writing serial, so the whole WebSocket path is testable on its own.

## Flashing the Arduino

Open [`arduino/belt.ino`](arduino/belt.ino) in the Arduino IDE, install the **Adafruit PWM Servo Driver** library (Library Manager), pick the board, and upload. It runs at 9600 baud, the same as `SERIAL_BAUD` below. Wire the PCA9685 servo pins per the sketch: front 0, right 1, back 2, left 3.

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

- **Server to belt (B1):** with the dashboard open, click a test button, or hit `http://localhost:8080/test?event=33&mask=4` (turn-now, Right -> `r`). The belt should fire, or in mock mode you see the command byte logged.
- **WebSocket to belt (B2 / B4):** run the stand-in phone, which streams a scripted cue sequence at 10 Hz:
  ```sh
  python test_client.py            # server on this machine
  python test_client.py <laptop-ip>
  ```

## Connecting the phone

The phone talks to this server over **UDP**, the same `LC2Transmitter` it would use for an ESP32, so no app change is needed. In the app's Control Panel, set the belt host to this laptop's IP and the port to `9999` (the default), then hit **Connect belt**. The server's UDP listener feeds the same path as the dashboard and test client.

```
ipconfig getifaddr en0     # this laptop's IP on macOS
```

Put the laptop and phone on the same network (laptop hotspot or a travel router is best; it gives the link clean airtime). Allow incoming connections if the firewall prompts. Watch `last_src` on the dashboard flip to the phone's IP once packets arrive.

The WebSocket endpoint (`ws://<laptop-ip>:8080/belt`) stays available for the stand-in test client and browser debugging, but the phone itself uses UDP.

## Wire format

- **In (WebSocket):** the 4 raw LC2 bytes per frame, `event, mask, intensity, seq`, exactly what the phone already builds. A JSON text frame `{"event":33,"mask":4,"intensity":192,"seq":0}` also works, for debugging.
- **Out (serial):** one ASCII byte per cue change, mapped from the cue by `lc2_to_command`:
  - `l` / `r` / `f` for a directional turn (mask bit Left `0x02`, Right `0x04`, Front `0x01`)
  - `s` for a hazard, obstacle, U-turn, or arrived cue (the stop/alert buzz)
  - nothing for idle (the belt finishes its pattern and falls quiet)

  Intensity, sequence, and any far-left/far-right distinction do not survive this mapping. The Arduino path is the coarse fallback; the ESP32 path (`firmware/`) keeps the full LC2 frame over UDP.

## Config (env vars)

| Var | Default | Meaning |
|---|---|---|
| `SERIAL_PORT` | auto-detect, then mock | serial device, or `mock` to force mock mode |
| `SERIAL_BAUD` | `9600` | matches `Serial.begin(9600)` in `arduino/belt.ino` |
| `PORT` | `8080` | HTTP / WebSocket port |
| `UDP_PORT` | `9999` | UDP port the phone sends LC2 to (matches iOS `espPort`) |
| `WARMUP_S` | `2.0` | pause after opening serial, for the Uno auto-reset |

## Notes

- The serial port is opened **once** and held for the whole session. Opening it resets the Arduino (its DTR auto-reset), so the server never reopens per message; it reconnects with a warmup only if the link drops.
- Latest-wins, change-only: only the most recent cue is considered, and a command byte is written only when it differs from the last one sent. The firmware's patterns are one-shot and return to idle on their own, so a held cue taps once and the belt falls quiet without needing a stop command.
- This server never decides cues. The phone owns all arbitration; this is a forwarder.
