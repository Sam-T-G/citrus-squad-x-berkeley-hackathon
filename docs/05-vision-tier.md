# 05 — Vision tier (Coral)

The vision tier is **conditional**. It ships only if Coral bring-up reaches green by Saturday H+12. If it does not, the tier cuts, the pitch reframes around direction-only with a disclosed sensing gap, and the team rejoins Tier-2.

This doc covers what it does, how it fits, and how to know whether to cut it.

## What it adds

Semantic obstacle detection on the belt. Camera sees a person walking into the wearer's path, Coral runs MobileNet-SSD over its Edge TPU, and if the criteria fire, it sends a single LC2 packet to the ESP32 that fires a sustained tap-train on the affected quadrant.

Where the deferred ToF tier would have given raw distance, Coral gives category. "There's a person 2 meters ahead and getting closer," not just "there's something 2 meters ahead." This is a real differentiation for the pitch.

## Architecture

Coral is a standalone safety node. It does not fuse with the phone, it does not know about the route, and it does not drive servos directly. The ESP32 stays the actuator brain.

```
[Camera] -> [Coral, runs MobileNet-SSD] -> [Trigger filter] -> [LC2 packet to ESP32]
```

Coral and the phone are independent senders that both target the same ESP32. The ESP32 deconflicts per the rule in [`03-protocol.md`](03-protocol.md) (Tier-3 wins on the affected quadrant; Tier-2 holds the rest).

## Trigger filter

A vision-danger event fires when all four conditions hold:

1. **Class match.** The model returns at least one detection with class `person`. (Initial set is just `person`; can expand to stairs, obstacles, etc. as a bonus.)
2. **Box size.** Bounding box height exceeds the proximity threshold. Initial guess: 150 pixels on a 640-pixel-tall frame. Tunable during M2-M4.
3. **Debounce.** The detection persists for ≥3 consecutive frames. Prevents single-frame false positives.
4. **Rate limit.** No vision-danger event has fired in the last 1.5 seconds. Prevents tap-train spam.

All four must hold. Tune the box-size threshold on the bench against a person standing 1.5 m, 2 m, and 3 m away. Pick the threshold that fires reliably at 2 m and not at 3 m.

## Quadrant mapping

The base layer ignores camera x-coordinate and treats every detection as centerline. Mask = `0x06` (Left + Right). The wearer feels tap-trains on both inner servos.

A bonus enhancement maps the box center x-coordinate to one of the four quadrants by camera FOV. Defer until the base layer is green.

## Network architecture

Coral talks to the ESP32. Four viable options, ranked by hack-window feasibility:

| Option | Approach | Pro | Con |
|---|---|---|---|
| **A. UART (recommended)** | USB-to-UART adapter on Coral, RX/TX on ESP32. 115200 baud. | Deterministic, no RF, no router dependency. | Coral and ESP32 must be physically adjacent. Cable management on the belt. |
| **B. BLE** | Coral as BLE central, ESP32 hosts a GATT characteristic. | No infrastructure. Paired connection. | Two BLE stacks to bring up (Mendel + ESP-IDF). More effort than UART. |
| **C. Wi-Fi UDP** | Coral joins the same Wi-Fi as the phone, sends UDP to the ESP32 alongside Tier-2 packets. | Reuses existing transport. | Router is the SPOF. Camera bandwidth could starve LC2 packets if Coral also streams frames to anything else (it should not). |
| **D. ESP32-AP** | ESP32 hosts a Wi-Fi access point. Phone and Coral both join. | No external router. | Phone loses internet access, cannot reach Google Maps. Breaks Tier-2. |

**Default: Option A (UART).** Lowest bring-up cost. Wire goes from Coral to ESP32 inside the belt; no RF involved. Confirm at the M0 Coral spike.

## Cut gate

If Coral has not emitted a valid LC2 packet that the ESP32 receives by Saturday **H+12** (about 11 PM Saturday), cut the Tier-3 layer. The owner rejoins Tier-2 or holds the demo lane. The pitch reframes to direction-only with a disclosed sensing gap.

The H+12 gate exists because vision integration past that point eats into the polish window and risks a half-shipped feature that confuses the demo more than it helps.

## Why the gate is real

The team has zero current Edge TPU fluency. From a cold start, the bring-up estimate is 12-16 hours of Linux + TFLite + model + camera + filter work. Pre-event learning compresses this to integration + tuning only, but only if the pre-event work actually happened.

If the Coral owner did not complete the Wednesday-Friday learning sprint (see [`08-team-roles.md`](08-team-roles.md)), the H+12 gate will fire by default and the cut is automatic.

## Pre-event learning sprint

Three evenings, sequenced so each builds on the last:

### Wednesday
- Identify the owner at the alignment meeting.
- Owner reads the Coral getting-started guide. About 60-90 minutes.
- Flash Mendel Linux to an SD card. Boot the Coral. SSH in. End-of-day checkpoint: shell on the Coral.

### Thursday
- Run the Coral hello-world inference example. Confirm Edge TPU is recognized and a pre-compiled MobileNet returns a label for a test image.
- Attach the camera. Stream frames. Confirm inference sees the camera input.

### Friday
- Run MobileNet-SSD on live camera frames at >10 FPS.
- Implement the trigger filter in Python.
- Emit a packet to a placeholder receiver (a laptop running `nc -u -l`). Confirm packet shape matches [`03-protocol.md`](03-protocol.md).

End-of-Friday checkpoint: Coral is sending valid LC2 packets when a person walks in front of the camera, observed on a laptop.

If the Friday checkpoint does not land, Coral is at high risk of missing the H+12 gate. The team should plan for the cut.

## Failure modes specific to Coral

- **Thermal throttle.** Edge TPU throttles under sustained load. Mitigate with a passive heatsink (Coral has one in the box). Test 30 minutes of continuous inference on the bench.
- **Camera frame drops.** USB webcams can drop frames if the kernel driver is unhappy. Use the Coral Camera if it works; fall back to a known-good USB webcam (Logitech C920 class).
- **Model false positives at the demo venue.** Lighting, background motion, judge crowd density. Mitigate by tuning the box-size threshold on Saturday morning at the venue, not in the lab.
- **Power draw.** Coral pulls 2-3 A peak; do not share the ESP32 power bank. Coral has its own power supply (USB-C, 5 V, 3 A).
