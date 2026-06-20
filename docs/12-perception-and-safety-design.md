# 12 — Perception and safety design (phone LiDAR and camera)

The phone's own LiDAR and camera are now part of the base plan, not the conditional Coral tier. This doc designs that layer to be reliable in the demo and genuinely useful to a blind or low-vision wearer. It is the safety counterpart to the direction layer in `docs/11`.

Pairs with:

- [`01-architecture.md`](01-architecture.md) — tier map. Needs the reconciliation in section 1 below.
- [`03-protocol.md`](03-protocol.md) — wire format. This doc reuses an existing event, it does not add a pattern.
- [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md) — Tier-2 direction contract. The arbitration in section 4 sits on top of it.
- `ios/Sources/Sensors/DepthService.swift` — the LiDAR service already scaffolded.

Status: locked as of 2026-06-20. Sam confirmed Coral drops to an optional sponsor stretch and gave the call on the rest. The architecture consolidation (section 1), the side convention (hazard tap means "obstacle is on this side"), and the safety-over-direction arbitration (section 4) are decided. The only deferred call is ARKit versus AVFoundation for depth, which waits on the thermal soak test. Section 11 has the record. Build against all of this now.

## 1. What changed, and the tier map it produces

The old plan put obstacle sensing on a separate Coral Dev Board because the phone was only doing direction and the team had no depth sensor on the belt. The iPhone 15 Pro Max already carries a LiDAR scanner and a camera. Folding them in does three good things at once: it revives the obstacle reflex the ToF deferral killed, it removes the Coral cold-start risk (the team had zero Edge TPU fluency and a 12 to 16 hour learning curve), and it drops the device count from three to two. The phone becomes sensing plus brain, the ESP32 stays the actuator.

Revised tiers, all on the same four servos:

| Tier | Purpose | Signal source | Status |
|---|---|---|---|
| **Direction** | turn left, turn right, arrived | phone Maps + compass | Primary base layer (`docs/11`) |
| **Proximity safety** | something is close ahead, on this side | phone LiDAR depth | Base layer, new |
| **Person-in-path** | a person is moving into your path | phone camera vision | Stretch on top of proximity |

What this means for Coral: the camera-plus-LiDAR phone path covers the safety story the Coral tier was there to tell. Coral is dropped from the base (locked). It survives only as an optional sponsor-angle stretch for spare hands, and the base demo does not depend on it. The reconciliation of the older Coral-centric docs is done in section 11.

The belt firmware learns one new event code, `0x40 obstacle-near`, which the build already added to `03`. It reuses the existing sustained tap-train pattern, so the wearer feels nothing new and the pattern cap holds. Teaching the ESP32 that code is the only belt-side change, and it is a one-line firmware addition.

## 2. What the perception layer emits

Both safety signals use the sustained tap-train pattern, so the four-pattern distinguishability cap in `03` holds and the wearer feels one "hazard on this side" cue regardless of source. They carry two different event codes only so firmware and logs can tell them apart and so a future Coral stretch slots in cleanly.

| Source | Event (byte 0) | Status | Notes |
|---|---|---|---|
| phone LiDAR proximity | `0x40` obstacle-near | base, committed | The event the build already added to `03` and wired through `LC2Packet`, `AppModel`, and the golden-vector test. This is the base safety signal. |
| phone camera person-in-path | `0x10` vision-danger | stretch | The camera detector emits this when a person is in the path. Coral reuses the same code if the sponsor stretch ever ships. |

Both events share these fields:

| Field | Value | Notes |
|---|---|---|
| mask (byte 1) | the hazard quadrant | from depth-zone sampling, section 5. The committed v1 sends center mass (`0x06`); section 3 makes it directional. |
| intensity (byte 2) | scaled by distance | closer means a larger tap travel. See below. The committed v1 sends the flat default; grading is the upgrade. |
| seq (byte 3) | transmitter's | unchanged, per `docs/11` |

Everywhere below that says "hazard," read it as "the `0x40` LiDAR cue today, plus the `0x10` camera cue if the stretch ships." The arbitration, the false-positive discipline, and the demo hardening apply to both the same way.

Distance-graded intensity is the one place the wearer gets analog information through a discrete channel. Map the nearest distance inside the threshold to the intensity byte so a thing at arm's length taps harder than a thing at the edge of the warning range:

```
intensity = clamp( map(nearest, dangerNear...thresholdMeters -> 255...96), 96, 255 )
```

Floor it at 96 so the cue is always felt, cap at 255. This is a nice-to-have, not a blocker. The base cue can ship at the flat `intensityDefault` and add grading later.

## 3. Directional obstacle, not just "something ahead"

The scaffolded `DepthService` samples a single patch at the center of the depth map and reports one distance. That answers "is anything ahead," which is not enough for a directional belt. A blind wearer needs to know which way to step to avoid the thing.

Sample three vertical bands of the depth map instead of one center patch: left third, center third, right third. Take the nearest valid reading in each. The band with the closest in-threshold reading sets the quadrant mask:

| Closest band | Mask | Quadrant felt |
|---|---|---|
| left third | `0x02` Left, or `0x01` Far Left if very close | hazard on the left, steer right |
| center third | `0x06` Left + Right | hazard dead ahead, stop |
| right third | `0x04` Right, or `0x08` Far Right if very close | hazard on the right, steer left |

The cue fires on the side the obstacle is on, not the side to move toward (locked). This keeps it consistent with the direction layer, where a tap on a side means "attention on this side." The wearer learns one rule. Verify it reads correctly with the wearer at the bench test, but the convention itself is set so the two layers never contradict.

## 4. Arbitration: safety wins, one packet per heartbeat

With the phone now the single sender of both direction and hazard, the deconfliction that `03` described as ESP32-side (Tier-3 wins on a quadrant, Tier-2 holds the rest) cannot happen in one four-byte packet, because one packet carries one event and one pattern. So the phone arbitrates before it sends. Per heartbeat tick, the transmitter emits the highest-priority active cue:

1. **Hazard active** (a settled obstacle or person in path): emit the hazard event on the hazard quadrant, `0x40` from LiDAR or `0x10` from the camera stretch. Suppress the turn cue.
2. **Else a turn is staged**: emit the turn cue per `docs/11`.
3. **Else**: emit `0x00` idle.

Safety preempts direction entirely while a hazard is active, rather than mixing them. The real-world reason is also the demo reason: a wearer who is about to walk into something should stop and clear it before being told to turn. A belt firing a turn cue and a danger cue in the same second is confusing for a person who cannot see which one matters. One clear signal at a time.

This makes the ESP32 deconfliction logic a backstop rather than the primary path. Leave it in the firmware in case Coral is ever re-added as a second sender, but the phone-only base does not rely on it.

## 5. Sensing design: make the LiDAR robust

Three things will break LiDAR proximity on a chest mount if they are not handled. Each has a fix.

**The ground plane will read as a constant obstacle.** A chest-mounted phone tilts down a few degrees naturally, so the LiDAR sees the floor two to three meters ahead and reports it as something close. Untreated, the belt buzzes the whole time the wearer walks. Two defenses, use both:

- Mount discipline: the phone sits near vertical, lens pointed level or a touch upward. Document the angle on the harness and check it at setup.
- Ground rejection in software: read the device pitch (ARKit gives camera transform, or CoreMotion gives gravity) and reject depth readings that fall on the expected floor line for that pitch and the known mount height. A reading is "floor" if its distance and vertical position match where the floor should be. When in doubt for a hackathon, the cheaper version is to sample an upper-center band that sits at torso and head height for nearby objects, which mostly dodges the floor without trig.

**LiDAR works in any light, the camera does not.** This is the reason proximity is the base layer and camera person-detection is the stretch. The LiDAR is active infrared, so it does not care about venue lighting, backlight, or glare. Lead the safety story with it. A demo that does not depend on room lighting is one less thing that can fail at the table.

**Range and threshold set the warning lead time.** Effective LiDAR range is about five meters, reliable under three. The scaffold default is 1.2 m, which is roughly one step of warning. For the person-walk-in demo beat, that is late. Use a tunable threshold and set it to about 1.8 to 2.0 m for the demo so the cue fires with enough lead to read as a real warning. Keep it in `CitrusSquadConfig`.

**Prefer the lighter capture path if there is time.** The scaffold uses ARKit `ARWorldTrackingConfiguration` with `.sceneDepth`. World tracking runs visual-inertial odometry the whole time, which is the heaviest thermal load on the phone and we do not use the pose it produces. `AVFoundation` can deliver LiDAR depth directly through `AVCaptureDevice.builtInLiDARDepthCamera` and `AVCaptureDepthDataOutput` without world tracking, which runs cooler and lets the same capture session feed both depth and the camera frames for person detection. The tradeoff is more setup code. ARKit is already working, so treat AVFoundation as the recommended optimization for thermal headroom, not a day-one rewrite. If the phone runs hot in the soak test (section 6), this is the first lever to pull.

## 6. Demo bulletproofing

Ranked by how badly each one can end the demo.

**Thermal is the new top risk.** Running depth capture continuously, plus GPS, plus the screen, plus UDP, on an iOS beta, across a multi-run demo, can push the phone to throttle or show a heat warning. Defenses:

- Keep the capture config minimal: no plane detection, no environment texturing, lowest depth-capable video format.
- Watch `ProcessInfo.processInfo.thermalState` and degrade on a ladder before the OS forces it: at `.serious`, drop camera person-detection and slow the depth read; at `.critical`, depth goes to a low rate and the app leans on direction only. The wearer always keeps the turn cues.
- Phone on the charger between runs. Do not leave the capture session running while the demo is idle; start it when a run starts.
- Add a thermal soak test to the Saturday checklist: run the full app for ten minutes and watch the thermal state. Do this before judging, not during.

**Mount geometry, covered in section 5.** Wrong tilt equals constant false alarms. Verify at setup.

**False positives create alert fatigue, which is worse than no alarm.** A safety cue that fires at every passing person and every wall on a turn trains the wearer to ignore it. Discipline:

- Settle requirement: a hazard has to persist for N consecutive reads (start with 3, about 300 ms) before it fires. Kills single-frame depth noise.
- Distance hysteresis: fire when nearer than `thresholdMeters`, clear only when farther than `thresholdMeters + 0.3`. Stops chattering at the boundary.
- Refractory period: after a hazard clears, hold off re-firing the same quadrant for a short window (about 1 s) so a person walking past does not produce a stutter of taps.
- Turn-aware suppression: while the wearer is mid-turn, the walls of the turn are expected and close. Optionally relax the proximity layer during an active turn cue so the geometry of the turn does not trip the alarm. Defer if time is short, but note it as the most likely demo false-positive.

**The person-in-path beat is a live mini-demo, so script it.** Navigation can replay a cached route, but a person walking in is inherently live. Make it repeatable: a teammate approaches the wearer along a marked line, from the front, in a clear lane, on the operator's cue. Define a clean start position and a stop line. Have a fallback if the camera detector misbehaves: the LiDAR proximity cue fires on the same approach regardless of the camera, so the safety beat still lands as "obstacle detected" even if "it is a person" does not. The camera adds the word "person," the LiDAR carries the demo.

**Permissions and signing, unchanged from `06`.** Camera permission is now genuinely needed because LiDAR is accessed through the camera stack. The Info.plist string should say plainly that the camera and LiDAR sense obstacles in the wearer's path. Install the demo build no earlier than Friday afternoon so the free-tier cert covers the Sunday demo.

## 7. Camera person-detection: the stretch, with a cut gate

Person detection is the differentiator, and it is also the most cuttable piece. Keep it cleanly separable so cutting it never touches the base.

- Use the Vision framework on-device (`VNDetectHumanRectanglesRequest`). It needs no model download, runs fast, and stays private. A full object detector (a CoreML model) is more than the demo needs and adds load and failure surface.
- Run it at a low rate, a few frames per second, on the camera frames the depth session already produces. Do not stand up a second capture session.
- Fuse simply: a person box whose center falls in a depth band that is within threshold means person-in-path. That gates camera false positives with LiDAR distance, which is more reliable than either signal alone.
- Cut gate: if person-detection is not firing cleanly on a walk-in test by the Saturday integration check, cut it. The proximity layer is the base and it already carries the safety beat. Person-detection becomes a one-line stretch in the pitch.

## 8. User-experience rules

The wearer cannot see the screen, so every choice has to make sense through taps alone.

- One hazard signal, one pattern. The wearer learns four patterns total: single tap (slight turn), triple tap (sharp turn or turn-around by mask), sweep (arrived), sustained tap-train (hazard). Do not add a fifth.
- Side convention is consistent across layers. A tap on a side means "pay attention to this side" for both turns and hazards. Lock the convention at the bench test and apply it everywhere.
- Stop, then go. While a hazard is active the belt says only "hazard," not "hazard and also turn." The wearer deals with the obstacle, then the direction cue returns. Section 4 enforces this.
- Quiet is a valid state and a safe one. When nothing is staged the belt is silent. Silence beats a stale or wrong cue. This is the same contract as the direction layer.
- Earn trust by not crying wolf. The settle, hysteresis, and refractory rules in section 6 exist so the wearer believes the belt when it does fire. For an assistive device, a believed cue is the whole product.

## 9. Concurrency notes for the build

The scaffolded `DepthService` already does the right thing: the `ARSessionDelegate` callback is `nonisolated`, the heavy depth read runs on ARKit's queue, and only a plain `Double` hops to the main actor, so the non-Sendable `ARFrame` never crosses an isolation boundary. Keep that shape for any new work.

- The three-band sampling and the settle and hysteresis state stay on the capture queue or in the service. Publish only the resolved hazard (quadrant plus distance) to the main actor.
- The hazard feeds the same arbitration point as the turn cue. The cleanest seam is in the staging loop: each tick, ask the depth service for the current hazard, ask the route engine for the current turn cue, apply the section 4 priority, and stage one packet. The transmitter still owns the heartbeat and the sequence byte. Nothing about `LC2Transmitter` changes.
- If AVFoundation depth replaces ARKit, the same isolation rule holds: resolve depth off the main actor, publish a small value type, never cross a buffer.

## 10. Build order delta

Adds to the milestone ladder in `docs/04` and `docs/11`. The direction layer milestones are unchanged. These slot in once M0 (the radio link) is proven.

- **P0**: depth service reports a stable nearest distance on the demo phone, with the ground plane rejected at the mount angle. Verify by walking toward a wall and watching the reading drop cleanly without the floor tripping it.
- **P1**: three-band sampling picks the correct quadrant for an obstacle on the left, center, and right.
- **P2**: hazard maps to a `0x10` packet on the right quadrant; the belt fires the sustained tap-train. Settle, hysteresis, and refractory rules are in.
- **P3**: arbitration. With both a staged turn and a live hazard, the belt fires only the hazard, then returns to the turn when the hazard clears.
- **P4**: thermal soak. Ten minutes of continuous run stays out of `.serious`, or the degrade ladder kicks in cleanly if it does not.
- **P5 (stretch)**: camera person-detection gated by depth, with its own cut gate.

P0 through P3 plus the direction layer's M5 is the bulletproof demo: route cues that replay reliably, and a live obstacle-and-person safety beat that does not depend on room lighting. P4 is what keeps it alive across multiple judging passes. P5 is the line that makes a judge remember it.

## 11. Decisions, locked and open

Decided 2026-06-20 by Sam.

1. **Coral is dropped from the base.** The phone LiDAR-plus-camera path carries the safety story. Coral survives only as an optional sponsor-angle stretch for spare hands. The team stops spending base-build time on it.
2. **Side convention is "obstacle is on this side"** (section 3), matching the turn-cue convention.
3. **Arbitration is whole-packet safety priority** (section 4). Hazard preempts the turn cue while active, then direction returns. No cross-heartbeat mixing.

Still open, on purpose:

4. **ARKit or AVFoundation for depth.** Ship on the working ARKit path for now. Revisit after the P4 thermal soak test. If the phone stays cool on ARKit, leave it; if it runs hot, move depth to AVFoundation (section 5).

Done as part of this decision:

5. **Canon reconciliation.** `00-overview.md`, `01-architecture.md`, `02-hardware.md`, `05-vision-tier.md`, and `IOS-APP-PLAN.md` were updated so the phone perception tier is the safety source and Coral reads as the optional sponsor stretch. The vision-danger packet now originates on the phone, which those docs had wrong.
