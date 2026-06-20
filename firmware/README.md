# Citrus Squad belt firmware (ESP32)

The receiving half of the link. The phone sends 4-byte LC2 packets over UDP at 10 Hz; this firmware drives the four tap servos to match. It is the executable form of the wire contract in [`../docs/03-protocol.md`](../docs/03-protocol.md), so the phone-side app has something concrete to send to.

This is the reference Angelo adapts for the real belt. It is deliberately small and non-blocking.

## What it does

- Brings up Wi-Fi, either hosting its own access point (default) or joining one.
- Listens for LC2 packets on UDP port 9999.
- Animates the four servos per the event: single tap (turn-slight), triple tap (turn-now / turn-around), sustained tap-train (obstacle-near / vision-danger), sweep (arrived).
- Falls back to quiet after 500 ms of silence, so a dropped link never leaves a stale cue buzzing.
- Logs sequence-number gaps so you can see packet loss on the Serial monitor.

## Wiring

From [`../docs/02-hardware.md`](../docs/02-hardware.md). Signal lines only go to the ESP32; servo power comes from the 5 V rail, never through the board.

| ESP32 pin | Servo |
|---|---|
| GPIO 25 | Far Left |
| GPIO 26 | Left |
| GPIO 32 | Right |
| GPIO 33 | Far Right |
| GPIO 18 | Status LED (link alive) through 220 Ω |

Put a bulk capacitor (1000 µF or larger) across the 5 V servo rail. The four-servo sweep can sag the rail and reboot the ESP32 without it.

## Flashing

1. Install the Arduino IDE and the ESP32 board package (Boards Manager, search "esp32").
2. Install the **ESP32Servo** library (Library Manager).
3. Open `citrus_squad_belt/citrus_squad_belt.ino`. Edit `config.h` if needed.
4. Select your ESP32 board and port, then Upload.
5. Open the Serial monitor at 115200 to see the network address and packet logs.

## Network setup

`config.h` has one switch, `AP_MODE`:

- **`AP_MODE 1` (default): the ESP32 hosts its own Wi-Fi.** Join `CitrusSquad-BELT` from the phone, and the belt is at `192.168.4.1` — which is the app's default host. No router, no venue Wi-Fi, nothing to type. Cost: the phone has no internet while joined, so live Maps is off (the replay/sim demo does not need it).
- **`AP_MODE 0`: the ESP32 joins your Wi-Fi or the phone hotspot.** Set `STA_SSID` / `STA_PASS`. The belt gets an address from that network; read it off the Serial monitor at boot and type it into the app's host field. Keeps phone internet for live Maps.

## Testing the link without the belt

Before servos are wired, you can prove the link from a laptop:

```sh
# listen as if you were the ESP32
nc -u -l 9999
```

Then point the app's host at the laptop's IP and tap "Send test cue." You will see the 4 raw bytes arrive. The phone app counts packets sent regardless, so a rising counter confirms the phone half is healthy.

## Pattern timing

Tuned in `config.h`: tap down/up at 80 ms each, sweep dwell at 140 ms per servo. If the servo clicks are loud in a quiet room, slow the tap-train (raise `TAP_UP_MS`). If the rail browns out on the sweep, the firmware already staggers servos one at a time rather than firing all four together.
