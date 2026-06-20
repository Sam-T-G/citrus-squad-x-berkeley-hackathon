# 05 — Safety tier (phone perception)

The safety tier is what the belt fires when something is in the wearer's way, separate from the turn-by-turn direction cues. It now runs on the phone's own LiDAR and camera, not on a separate vision board. The full design, including the false-positive discipline, the arbitration against direction cues, and the demo hardening, lives in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md). This doc is the short version plus the optional Coral stretch that an earlier plan built around.

## What it adds

Two signals, both felt as the sustained tap-train pattern:

- **Proximity, from LiDAR (base).** The iPhone 15 Pro Max LiDAR scanner reads scene depth. When something is close on a given side, the phone emits `0x40 obstacle-near` on that quadrant. This revives the obstacle reflex the old plan deferred for lack of a ToF sensor. The phone is the ToF sensor, and a far better one. LiDAR is active infrared, so it works in any venue lighting.
- **Person-in-path, from the camera (stretch).** On-device Vision detects a person and the phone gates it with LiDAR distance, then emits `0x10 vision-danger`. Same feel as proximity, distinct code so logs and firmware can tell them apart.

Where a cane catches things at foot level, this catches upper-body and approaching obstacles. That is the differentiation for the pitch, and it needs no hardware on the belt.

## How it fits

The phone is the single LC2 sender, so it arbitrates: a settled hazard preempts the staged turn cue for that heartbeat, then direction returns once the hazard clears. The belt firmware learns one new event, `0x40`, which reuses the existing sustained tap-train pattern, so the four-pattern cap in [`03-protocol.md`](03-protocol.md) holds. The ESP32 just renders whatever event the phone sends.

The design details that make the cue trustworthy (three-band directional sampling, ground-plane rejection, settle and hysteresis and refractory filtering, distance-graded intensity, and the thermal degrade ladder) are all in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md). Build against that doc.

## Cut behavior

There is no hard cut gate on proximity, because it is a base layer with low cost and no cold-start risk. If the LiDAR misbehaves at the venue, the proximity cue goes quiet and the rest of the system keeps working, the same as any other sensor dropping.

The camera person-in-path stretch does have a cut gate: if it is not firing cleanly on a walk-in test by the Saturday integration check, cut it. The LiDAR proximity cue fires on the same approach regardless of the camera, so the safety beat still lands as "obstacle detected." The camera only adds the word "person."

---

## Optional sponsor stretch: Coral Edge TPU

An earlier plan put the vision tier on a Coral Dev Board. The phone path replaced it for the base, but the Coral is in hand and can run as a sponsor-angle stretch if someone has spare hands and wants the Google Edge TPU story. Nothing in the base demo depends on it. Everything below is preserved for that optional path.

### What Coral would add

Semantic detection on its own node: camera sees a person, Coral runs MobileNet-SSD over its Edge TPU, and on a trigger it sends an LC2 packet to the ESP32. Coral does not fuse with the phone, does not know the route, and does not drive servos. It would be a second LC2 sender, and the ESP32 deconfliction backstop (Tier-3 wins on the affected quadrant, direction holds the rest) is what mixes it with the phone stream.

```
[Camera] -> [Coral, runs MobileNet-SSD] -> [Trigger filter] -> [LC2 packet to ESP32]
```

### Trigger filter

A vision-danger event fires when all four conditions hold:

1. **Class match.** At least one detection with class `person`.
2. **Box size.** Bounding box height exceeds the proximity threshold. Initial guess: 150 pixels on a 640-pixel-tall frame. Tunable.
3. **Debounce.** The detection persists for at least 3 consecutive frames.
4. **Rate limit.** No vision-danger event has fired in the last 1.5 seconds.

Tune the box-size threshold on the bench against a person at 1.5 m, 2 m, and 3 m. Pick the threshold that fires reliably at 2 m and not at 3 m.

### Network and power for Coral

If Coral ships, it talks to the ESP32 over UART (recommended: USB-to-UART, 115200 baud, deterministic, no router dependency). Coral pulls 2 to 3 A peak and runs from its own power supply, never the ESP32 power bank. It has a passive heatsink; the Edge TPU throttles under sustained load, so bench test 30 minutes of continuous inference before relying on it.

### Coral cut gate

If Coral has not emitted a valid LC2 packet the ESP32 receives by Saturday H+12, the stretch is dropped and whoever was on it rejoins the base. The team has zero current Edge TPU fluency, so a cold-start bring-up is 12 to 16 hours. This is exactly why it is a stretch and not the base. The base safety story is already covered by the phone LiDAR.
