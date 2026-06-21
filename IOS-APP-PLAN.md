# IOS-APP-PLAN.md — Citrus Squad phone-side app

The engineering plan for the iOS app that owns Tier-2 of Citrus Squad. This realizes the phone responsibilities described in `docs/01-architecture.md` and `docs/04-phone-side.md`. Those docs own the product spec and the wire protocol. This doc owns how we build the app that satisfies them.

Status: native iOS Swift is the chosen stack. The base app is scaffolded and compiling under Swift 6 strict concurrency in [`ios/`](ios/). Craft rules live in [`SWIFT.md`](SWIFT.md). The per-module build contract (the one decision function, ownership of each tricky byte, the bearing-to-bytes table) lives in [`docs/11-phone-app-design-spec.md`](docs/11-phone-app-design-spec.md); when an implementation detail here and there disagree, `docs/11` wins.

## What the phone is responsible for

From the architecture, the phone is the only device with GPS, a magnetometer, and the cellular link to Google Maps. Its job in the running system:

1. Pull walking directions once at route start and cache every maneuver point.
2. Every second, read GPS and true heading, compute the body-relative bearing to the next maneuver, and decide which belt quadrant should fire and with what event.
3. Every 100 ms, emit one LC2 packet to the ESP32: either the staged turn cue or a `0x00` idle.
4. Survive a venue with bad Wi-Fi and bad GPS by replaying a pre-cached route instead of a live one.

Everything below serves those four jobs. Nothing else ships before they work.

## Architecture at a glance

Service-oriented with one main-actor app model on top. Features are vertical slices, not horizontal layers.

A check means the module exists and compiles in the base scaffold. The rest are planned.

```
CitrusSquadApp (@main)                                                              [x]
  └── AppModel  (@MainActor, @Observable)   wires services, runs staging loop [x]
        │     CitrusSquadConfig         one home for the tunable numbers             [x]
        │
        ├── Routing/
        │     Bearing            pure geometry: haversine, relative bearing   [x]
        │     RouteEngine        QuadrantMapper + calibration + current cue   [x]
        │     DirectionsClient   one Google Maps Directions call, caches it   [ ]
        │
        ├── Sensors/
        │     LocationService    CLLocationManager: GPS + true heading        [x]
        │     MotionService      CMMotionManager: accel + gyro at 50 Hz       [x]
        │     DepthService       ARKit LiDAR scene depth: nearest obstacle    [x]
        │
        ├── Networking/
        │     LC2Packet          codec: event to 4 bytes per docs/03          [x]
        │     LC2Transmitter     actor: UDP socket + 100 ms heartbeat loop    [x]
        │
        ├── Replay/
        │     RouteReplayer      feeds recorded samples into RouteEngine      [ ]
        │
        └── UI/
              ControlPanelView   one card per subsystem, nav bench, link      [x]
              Cards              reusable status card + labeled row           [x]
```

## The critical path, in code terms

This maps the Tier-2 data flow from `docs/01-architecture.md` onto the modules above.

- **At route start**, `AppModel` asks `DirectionsClient` for the route. One HTTPS call through `URLSession`. The client decodes the response into a cached array of maneuver points and hands it to `RouteEngine`. If the call fails, the app falls back to a bundled cached route so the demo is never blocked on the network.
- **Once per second**, a tick task in `AppModel` reads the latest `LocationService` fix and heading, then calls `RouteEngine.update(location:heading:)`. The engine uses `Bearing` to compute the body-relative angle to the next maneuver, picks the quadrant mask, and decides the event (turn-slight, turn-now, turn-around, or none). It stages that as the current cue.
- **Every 100 ms**, the `LC2Transmitter` actor wakes, asks `RouteEngine` for the staged cue, encodes it with `LC2Packet`, and sends it over UDP. If no cue is staged, it sends the `0x00` idle packet. This cadence is what lets the ESP32 fall back to quiet after 500 ms of silence, exactly as the failure-modes doc requires.

The one-second decision loop and the 100 ms send loop are deliberately separate. The decision loop can be slow and thoughtful. The send loop is dumb and metronomic. Keeping them apart means a slow Directions decode never stalls the heartbeat.

## Why the LC2 transmitter is an actor

The send buffer is touched by two callers: the route engine staging a new cue, and the heartbeat reading the current cue. That is shared mutable state across tasks, which is the textbook case for an `actor`. The transmitter owns the `NWConnection`, owns the staged cue, and serializes both accesses. No locks, no `DispatchQueue`, no data race. The heartbeat is a cancellable `Task` running `Task.sleep(for: .milliseconds(100))` in a loop, not a `Timer`.

## Replay-first, because the venue will fight us

The demo plays a pre-cached route, per the lock in `docs/00-overview.md`. `RouteReplayer` holds a recorded sequence of GPS fixes and headings captured on a real walk. In replay mode it feeds those samples into `RouteEngine` on the same one-second cadence the live sensors would. The engine, the transmitter, and the belt cannot tell the difference between live and replayed input, which is the point: the exact code path that runs in the field also runs in the demo.

Live outdoor input is a runtime toggle on top of the same engine, not a separate code path. Live is the bonus, replay is the baseline.

## Wire protocol boundary

`LC2Packet` implements the byte layout defined in `docs/03-protocol.md`. That doc is the source of truth for the format. This app plan does not restate the byte fields, to avoid the two docs drifting apart. What this app guarantees:

- Every packet the app emits round-trips through the same encoder, including the idle packet.
- The encoder has a golden-vector unit test asserting exact bytes for known inputs, so a protocol change shows up as a failing test, not as a confused belt.
- The app never invents an event the protocol does not define. New events are added to the protocol doc first, then the encoder.

The phone now emits the safety events too. `0x40 obstacle-near` comes from the LiDAR depth read (base, wired below), and `0x10 vision-danger` comes from the camera tier. The base-demo beat for `0x10` is person-in-path, but as of commit `3c83f75` the camera tier recognizes the full `CitrusSquadConfig.visionNavigationClasses` set (21 COCO classes), so the cue can fire on any in-path object and the overlay/diagnostics name what it is. The event byte does not encode class; identity rides on the spoken/diagnostics layer only. The phone arbitrates a hazard against the staged turn cue before sending, so it never puts two events in one packet. The arbitration and the perception design live in [`docs/12-perception-and-safety-design.md`](docs/12-perception-and-safety-design.md). Coral, if the optional sponsor stretch ships, would be a second sender of `0x10`.

## Depth sensing (LiDAR)

The iPhone 15 Pro Max has a LiDAR scanner, and `DepthService` reads it through ARKit scene depth. It samples a small patch at the center of the depth map and reports the nearest distance straight ahead, plus an "obstacle within threshold" flag. ARKit hands frames to a background queue, so the service pulls the nearest distance off the depth buffer on that queue and hops only the `Double` to the main actor. The non-Sendable `ARFrame` never crosses an isolation boundary.

This is the piece that does not yet have a home in the protocol. The phone's LiDAR gives raw proximity, which is exactly what the deferred Tier-1 obstacle reflex needed; `docs/01-architecture.md` deferred Tier-1 only because there was no ToF sensor in hand. The phone is the ToF sensor. So the phone could revive a Tier-1 "something is right in front of you" cue with no extra hardware.

It now emits a cue too. `docs/03-protocol.md` gained a provisional `0x40 obstacle-near` event that reuses the sustained tap-train pattern, so it stays inside the four-pattern cap. When depth is running and something is closer than `thresholdMeters`, `AppModel` stages the obstacle cue with priority over the route cue for that heartbeat. A toggle on the depth card turns this on and off so the route path can be tested clean.

Everything about this tier is provisional and changeable at any time: the event code, the threshold, the mask, the priority, whether it ships at all. It is wired now so the team can feel it on the bench and decide. The one place it reaches outside the phone is the ESP32 firmware, which has to learn the new code, so a quick sync with the belt owner is the only coordination it needs.

The camera permission question is settled. Sam owns the project design and made the call: LiDAR depth is part of the app, and since ARKit depth needs `NSCameraUsageDescription`, that key stays. `docs/11-phone-app-design-spec.md` has been updated to match, so there is no drift.

## Build order during the hack

Aligns with the gates in `docs/07-timeline.md`. The base scaffold already covers the structure for steps 1 through 3; the work left is wiring real data through them.

1. **Sensor services ported.** `LocationService` and `MotionService` carry the probe's proven configuration into the Swift 6 `@Observable` shell. Confirm heading and GPS read clean on the demo phone.
2. **`LC2Transmitter` and `LC2Packet` stood up.** The "Send test cue" button on the control panel fires a known packet on the 100 ms heartbeat. This is the M0 link check: belt twitches on command.
3. **`Bearing` and `QuadrantMapper` built and unit tested.** The nav bench card drives the full heading-to-cue path: calibrate, set a target bearing, rotate the phone, watch the cue change and transmit. Add the `RouteEngine` hysteresis deadband next, per `docs/11`.
4. **Add `RouteReplayer` and a recorded route.** This is the demo path. Get it solid before touching live Maps.
5. **Add `DirectionsClient`** for the live bonus. Falls back to the cached route on any failure.
6. **Harden `ControlPanelView`** for the demo: packet log, live/replay toggle, larger touch targets.

If time runs short, the cut line is after step 4. Replay demo plus a working belt is a complete story. Live Maps is the part the pitch can disclose as a stretch.

The base diverges from `docs/11` in one place worth noting: the staging loop runs at 10 Hz, not the 1 Hz the contract specifies for the GPS-driven path. That is deliberate for the bench, where the loop is driven by live heading and a faster refresh makes the cue feel responsive while rotating the phone. When GPS and Maps land, the cadence follows `docs/11` (1 Hz poll).

## What this app is not

- Not the belt firmware. The ESP32 turning events into PWM lives in a separate part of the repo once the stack lands.
- Not the belt-side rendering of the safety tier. The phone senses and arbitrates the hazard, but the ESP32 turns the event into taps. The perception design is in `docs/12-perception-and-safety-design.md`.
- Not a general navigation app. It computes one thing: which quadrant to tap next. Everything else is in service of that.

## Open questions for the team

- **Camera permission.** Resolved. LiDAR is in, so `NSCameraUsageDescription` stays. `docs/11` updated to match.
- **Obstacle cue over LC2.** Wired, provisional. `0x40 obstacle-near` is in `docs/03` and the phone emits it. Open parts: tune the threshold and mask on the bench, confirm the local priority over route cues feels right, and teach the ESP32 firmware the new code. All of it is changeable; nothing is locked.
- **UDP transport.** Confirm the phone-to-ESP32 link host and port match what the ESP32 firmware listens on. The control panel defaults to `192.168.4.1:9999`; change it there or in `AppModel`.
- **Replay route.** Decide whether the recorded replay route is captured before the hack or during setup on Saturday.
