# 02 — Hardware

## Bill of materials

| Qty | Part | Notes |
|---|---|---|
| 4 | Hobby servo (SG90-class or similar) | Tap actuators. Drive arm ~30° travel, return to neutral. One per quadrant: Far Left, Left, Right, Far Right. |
| 2 | Spare servos | Per the "two of every SPOF part" rule. |
| 1 | ESP32 NodeMCU dev board | 30-pin or 38-pin variant. 3.3 V logic, built-in Wi-Fi. |
| 1 | Spare ESP32 | SPOF redundancy. |
| 1 | Coral Dev Board (Google I/O Edition) | Tier-3 vision. Already in hand. No spare available. |
| 1 | Coral Camera or USB webcam | Whichever has working drivers under Mendel Linux. |
| 1 | Chest harness (sturdy running mount for the phone) | ~$25. Phone faces forward, rigid retention. |
| 1 | Momentary push-button | Calibration trigger if the belt-side button option ships. ~$2. |
| 1 | SPST slide switch | Power switch for the belt electronics. ~$2. |
| 1 | Status LED + 220 Ω resistor | Power-on indicator. ~$1. |
| 1+ | Bulk capacitor (1000 μF or larger) | Across the servo power rail. Smooths simultaneous-actuation current draw. |
| 1 | 5 V USB power bank (≥2.1 A) | Powers the ESP32 and the servo rail. |
| 2 | Spare power banks | SPOF redundancy. |
| 1 | Travel Wi-Fi router OR phone hotspot | Network choice in [`03-protocol.md`](03-protocol.md). |

## Pinout

| ESP32 pin | Connected to | Mode |
|---|---|---|
| GPIO 25 | Servo 1 signal (Far Left) | PWM output, 50 Hz |
| GPIO 26 | Servo 2 signal (Left) | PWM output, 50 Hz |
| GPIO 32 | Servo 3 signal (Right) | PWM output, 50 Hz |
| GPIO 33 | Servo 4 signal (Far Right) | PWM output, 50 Hz |
| GPIO 18 | Status LED through 220 Ω | Digital output |
| GPIO 5 | Calibration push-button | Digital input with internal pull-up |
| VIN | 5 V power-bank positive | Power input |
| GND | Common ground (power bank, servos, ESP32) | Ground reference |

Servo power lines go directly to the 5 V rail from the power bank, not through the ESP32. Only the signal lines connect to GPIO. This is critical for stall-current handling.

## Servo signal level

Hobby servos expect a 5 V PWM signal at the spec level, but most accept 3.3 V from ESP32 GPIO. Confirm at the M0 bench test. If signal level is marginal:

- Add a logic-level shifter on each signal line (cheap, four channels), or
- Use a PCA9685 PWM controller over I2C (one chip, 16 channels, 5 V output, gives us headroom for future expansion).

Decide at M0 servo spike. The PCA9685 is more elegant; the level shifter is faster to wire.

## Power budget

| Load | Current draw | Notes |
|---|---|---|
| ESP32 idle + Wi-Fi | ~120 mA | Steady draw. |
| One servo holding position | ~50 mA | Steady. |
| One servo actuating | ~200-400 mA | Brief peak during arm motion. |
| Four servos actuating simultaneously (sweep pattern) | ~800-1500 mA peak | This is the worst case the rail must survive. |
| Coral Dev Board | ~2-3 A peak under load | Has its own power supply; do not share the ESP32 power bank. |

The ≥2.1 A power bank handles steady draw plus one or two servos. The four-servo sweep is what the bulk capacitor smooths. Without bulk capacitance, simultaneous actuation can sag the rail enough to brown out the ESP32. Bench test the sweep pattern under load before the hack starts.

Coral runs from its own power source. Treat it as a separate electrical system that happens to share the belt.

## Harness

The phone goes on a chest harness, screen facing inward, camera and back facing forward. The harness must:

- Hold the phone rigid relative to the wearer's torso. Any wobble shows up as compass noise. The compass is the entire point of the build.
- Not move during walking. A loose harness adds heading error proportional to the wobble.
- Allow one-handed mounting and removal. The wearer should not need help to put it on.

The four servos mount on the chest/torso side. Spacing is wide enough that the wearer can distinguish which one tapped without looking. Approximate spacing: Far Left and Far Right near the outer shoulders, Left and Right near the inner collarbone. Tune at the M2 bench test.

The ESP32, power bank, and Coral go in a small pouch on the back of the belt. The wire runs from each servo to the ESP32 along the inside of the belt; the wires must not catch on clothing.

## Spares

The hardware-discipline rule is "two of every SPOF part" for everything that, if it dies, kills the demo:

- 2 ESP32 boards (we have one in active, one boxed and ready)
- 6 servos (4 in active, 2 spare)
- 2 power banks
- 1 Coral Dev Board (we only have one; if it dies, Tier-3 is cut)

Pre-charge both spare power banks Friday night.

## Pre-event bench tests

Before the hack starts, run these tests on the bench:

1. ESP32 drives one servo through the full pattern vocabulary (single, triple, sweep, sustained tap-train). Confirms signal level and PWM cadence.
2. Four-servo sweep under load. Confirms the power bank + bulk capacitor combo holds the rail.
3. UDP packet sent from a laptop on the same Wi-Fi reaches the ESP32 within 100 ms.
4. Coral boots Mendel Linux, runs the hello-world inference, attaches to a camera, and runs the trigger filter at >10 FPS.

If any of these fails the night before, fix it before opening ceremony. The hack window is not for bring-up.
