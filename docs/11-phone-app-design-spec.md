# 11 — Phone app design spec (build contract)

This is the single place that says how the phone-side modules actually behave, so whoever writes the Swift never has to reconcile `03-protocol.md` and `04-phone-side.md` by hand. It deepens those two docs and `IOS-APP-PLAN.md`. It does not replace them.

Pairs with:

- [`03-protocol.md`](03-protocol.md) — wire format. Owns the bytes.
- [`04-phone-side.md`](04-phone-side.md) — product behavior. Owns heading math, calibration, milestones.
- [`IOS-APP-PLAN.md`](../IOS-APP-PLAN.md) — module map.
- [`SWIFT.md`](../SWIFT.md) — craft rules.

Precedence rule: for a phone-app implementation detail (what a module emits, where a value lives, who owns a byte), this doc wins. For a product or protocol question (what the wearer should feel, what the byte layout is), `04` and `03` win, and if this doc disagrees with them it is a bug to fix here.

## Why this doc exists

The behavior an implementer needs is split across two files today. `03` gives the event codes and the mask bits. `04` gives the bearing bands and the patterns. Neither one states the function the `RouteEngine` has to compute: "given where the wearer is and which way they face, produce the exact four bytes to send." That function is below, derived once, so it does not get re-derived three different ways in three different commits.

## The one decision function

Everything the `RouteEngine` does collapses to one pure-ish function. Given the current fix, the heading, the calibration offset, the cached route, and the previous quadrant, produce a cue or nothing.

Define a cue as three values that map straight onto LC2 bytes 0 through 2:

```
struct Cue {
    let event: UInt8      // byte 0
    let mask: UInt8       // byte 1
    let intensity: UInt8  // byte 2  (byte 3, seq, is the transmitter's, not the engine's)
}
```

Steps, in order:

1. Body heading from phone heading and the calibration offset:
   `body_heading = (trueHeading - calibrationOffset + 360) % 360`
2. Find the active maneuver (the next one not yet passed). Read its `route_bearing` (true-north degrees from the Maps step).
3. Distance to that maneuver by haversine. If the wearer has not crossed the turn-commit threshold yet (`turnCommitMeters`, default 5), stage nothing. The heartbeat keeps sending idle. Staging happens at the moment the wearer crosses the threshold approaching the maneuver.
4. Body-relative bearing:
   `body_relative = (route_bearing - body_heading + 360) % 360`
5. Pick the quadrant from `body_relative`, applying hysteresis against the previous quadrant (see below).
6. Map the quadrant to `(event, mask)`. Set `intensity = intensityDefault` (192).
7. At the final maneuver, emit `arrived` instead of a turn.

## The bearing to bytes table (single source)

This merges the `04` bearing bands with the `03` event codes and mask bits. Use it verbatim. Do not rebuild it by reading `03` and `04` separately.

| Body-relative bearing | Quadrant | Event (byte 0) | Mask (byte 1) | Pattern |
|---|---|---|---|---|
| 350° to 10° (forward) | none | no cue staged | — | none |
| 10° to 60° | Right | `0x20` turn-slight | `0x04` | single tap |
| 60° to 120° | Far Right | `0x21` turn-now | `0x08` | triple tap |
| 120° to 240° | both Far | `0x22` turn-around | `0x09` | triple tap, both Far servos |
| 240° to 300° | Far Left | `0x21` turn-now | `0x01` | triple tap |
| 300° to 350° | Left | `0x20` turn-slight | `0x02` | single tap |
| at final maneuver | sweep | `0x23` arrived | `0x0F` | sweep left to right |

Mask bit reference (from `03`): bit 0 = Far Left (`0x01`), bit 1 = Left (`0x02`), bit 2 = Right (`0x04`), bit 3 = Far Right (`0x08`). Both-Far is `0x01 | 0x08 = 0x09`. All four is `0x0F`.

Note the asymmetry that is correct on purpose: a gentle turn (Left or Right band) is `turn-slight` with a single tap, a sharp turn (Far Left or Far Right band) is `turn-now` with a triple tap. The event encodes the pattern, the mask encodes the side.

## Where each tricky value lives

These four ownership calls are the ones that go wrong if left implicit.

**Hysteresis belongs to `RouteEngine`, not `Bearing`.** `04` calls for a deadband of ±5° on adjacent quadrant transitions and ±10° on the turn-around case so the cue does not flicker when the wearer's heading sits on a boundary. Applying it needs the previous quadrant, which is state. So `Bearing` stays pure and stateless (haversine, relative bearing, raw-quadrant-from-angle), and `RouteEngine` holds `previousQuadrant` and applies the deadband on top of `Bearing`'s raw answer. This keeps `Bearing` unit-testable as plain functions.

**The sequence number belongs to `LC2Transmitter`.** Byte 3 is a rolling counter for staleness detection. The transmitter increments it once per emitted packet, every heartbeat tick, idle packets included, wrapping 255 back to 0. `RouteEngine` and `LC2Packet` never touch it. This matters because the counter has to be monotonic across the whole stream, and only the transmitter sees the whole stream.

**The intensity default belongs to a constant.** `192` per `03`. `RouteEngine` sets it from the constant on every cue. A bonus feature may modulate it later. The base path always sends 192.

**The idle packet is fully specified.** Event `0x00`, mask `0x00`, intensity `0`, seq from the transmitter. The transmitter sends this whenever no cue is staged. It is what lets the ESP32 fall back to quiet after 500 ms of silence.

## Constants in one place

Put these in a single `CitrusSquadConfig` namespace so no magic numbers scatter across modules. Values come from `03`, `04`, and the probe.

| Name | Value | Source |
|---|---|---|
| `turnCommitMeters` | 5 | `04` Maps integration |
| `rerouteDeviationMeters` | 25 | `04` Maps integration |
| `heartbeatMilliseconds` | 100 | `03` cadence |
| `gpsPollHz` | 1 | `04` |
| `headingFilterDegrees` | 1.0 | probe `LocationHeadingService` |
| `motionUpdateInterval` | 0.02 | probe `MotionService` (50 Hz) |
| `hysteresisAdjacentDegrees` | 5 | `04` quadrant mapping |
| `hysteresisTurnAroundDegrees` | 10 | `04` quadrant mapping |
| `intensityDefault` | 192 | `03` byte 2 |
| `linkSilenceTimeoutMilliseconds` | 500 | `03` / `06` (ESP32 side, here for reference) |

## Two loops, one engine

The decision loop and the send loop run at different rates and must not block each other.

- **Decision loop, 1 Hz.** A tick `Task` on `AppModel` reads the latest fix and heading, calls `RouteEngine.update(...)`, and stages the resulting cue (or clears it) on the transmitter.
- **Heartbeat loop, 10 Hz.** Lives inside the `LC2Transmitter` actor. Each tick reads the currently staged cue, or the idle cue if none is staged, encodes it with `LC2Packet`, increments the sequence byte, and sends over UDP.
- **The coupling point** is the staged cue inside the actor. The decision loop writes it through `stage(_:)`. The heartbeat reads it. The actor serializes both accesses, so there is no lock and no data race. A slow Maps decode in the decision loop never stalls the metronomic heartbeat.

Both loops are cancellable `Task`s using `Task.sleep(for:)`, not `Timer`, per `SWIFT.md`.

## Porting the probe: it is configuration, not code

`wand-phone-probe`'s `LocationHeadingService` and `MotionService` are proven on the demo phone. What is proven is the sensor configuration: `desiredAccuracy = kCLLocationAccuracyBest`, `headingFilter = 1.0`, the `CMMotionManager` update interval of `0.02`, the delegate wiring for heading plus GPS on one `CLLocationManager`. Carry those numbers across exactly.

What does not carry across is the concurrency shell. The probe targets iOS 16, so it uses `ObservableObject`, `@Published`, `Combine`, and `DispatchQueue.main.async` inside delegate callbacks. The production app is iOS 17 with Swift 6 strict concurrency. Translate the shell:

- `final class ... : ObservableObject` with `@Published` becomes `@MainActor @Observable final class`.
- Drop `import Combine`.
- Replace `DispatchQueue.main.async { self.x = ... }` in delegate methods with a main-actor hop. Either mark the delegate conformance `@MainActor` and update observable state directly, or bridge the delegate stream through an `AsyncStream` the service consumes on the main actor.
- The service exposes an `@Observable` snapshot the `AppModel` reads each tick. No `@Published`, no Combine subscriptions.

Do not paste the probe files in and silence the warnings. Port the config, rewrite the shell, keep the magic numbers.

## Permissions

The app declares three keys in `ios/Sources/Info.plist` and `ios/Project.yml`: Location (when in use), Motion, and Camera.

- **Location** drives GPS and heading. Tier-2 core.
- **Motion** drives the 50 Hz bonus features. Used.
- **Camera** is required by ARKit scene depth, which is how the phone reads its LiDAR scanner. Used by `DepthService`.

The earlier draft of this doc recommended dropping `NSCameraUsageDescription` on the grounds that Tier-2 has no camera feature. That is superseded. Sam's authoritative design call adds phone-side LiDAR depth sensing to the app, and ARKit depth needs the camera permission. The string is honest about what it does: "Citrus Squad uses the LiDAR depth camera to sense nearby obstacles." All three keys stay.

One operational note still holds: each permission is a prompt the operator taps through at first launch. Grant all three before the demo so none of them surface on stage.

## What "done" means per module

Each module has a testable bar. These line up with the milestones in `04`.

- **`Bearing`** — pure functions, unit tested. The eight cardinal directions and the documented band boundaries map to the right quadrant. Haversine matches a hand-computed sample within 1°.
- **`LC2Packet`** — golden-vector test. The exact bytes for idle, turn-slight (Right), turn-now (Far Right), turn-around, and arrived match `03`. This is the single most valuable test in the repo; a wire-format bug is invisible until the belt does the wrong thing.
- **`LC2Transmitter`** — actor. Sends at roughly 10 Hz. The sequence byte increments and wraps. Staging from the decision loop and reading from the heartbeat compile clean under strict concurrency with no warnings.
- **`LocationService` / `MotionService`** — `@Observable`, read clean on the demo phone, no concurrency warnings. Body heading holds within ±10° while the phone sits still.
- **`RouteEngine`** — given a synthetic sequence of fixes and headings against a known route, it stages the expected cue sequence. Hysteresis holds: dithering the heading ±3° around a band boundary produces no quadrant change.
- **`RouteReplayer`** — feeds a recorded sample sequence into `RouteEngine` at 1 Hz, the same code path the live sensors drive.
- **`ControlPanelView`** — connection status, current cue, packet log, live/replay toggle, calibrate button. Accessibility per `SWIFT.md`: Dynamic Type, VoiceOver labels, no color-only status.

## One ordering note for the build

`04`'s M0 milestone is "send one UDP packet the ESP32 receives." `IOS-APP-PLAN.md`'s build order lists porting the sensors first. Both are cheap. Prefer the `04` order: stand up `LC2Packet` and `LC2Transmitter` and fire a hardcoded packet at the ESP32 before anything else. The radio link is the highest-risk unknown in the whole phone app, and proving it first de-risks every module that follows. The sensor port is low-risk and can land right after.
