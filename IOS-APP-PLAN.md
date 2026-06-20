# IOS-APP-PLAN.md — WAND phone-side app

The engineering plan for the iOS app that owns Tier-2 of WAND. This realizes the phone responsibilities described in `docs/01-architecture.md` and `docs/04-phone-side.md`. Those docs own the product spec and the wire protocol. This doc owns how we build the app that satisfies them.

Status: iOS-native track. Applies once the team confirms Swift at the alignment meeting. Craft rules live in [`SWIFT.md`](SWIFT.md).

## What the phone is responsible for

From the architecture, the phone is the only device with GPS, a magnetometer, and the cellular link to Google Maps. Its job in the running system:

1. Pull walking directions once at route start and cache every maneuver point.
2. Every second, read GPS and true heading, compute the body-relative bearing to the next maneuver, and decide which belt quadrant should fire and with what event.
3. Every 100 ms, emit one LC2 packet to the ESP32: either the staged turn cue or a `0x00` idle.
4. Survive a venue with bad Wi-Fi and bad GPS by replaying a pre-cached route instead of a live one.

Everything below serves those four jobs. Nothing else ships before they work.

## Architecture at a glance

Service-oriented with one main-actor app model on top. Features are vertical slices, not horizontal layers.

```
WANDApp (@main)
  └── AppModel  (@MainActor, @Observable)   owns app state, wires services together
        │
        ├── Routing/
        │     RouteEngine        decides quadrant + event from position and heading
        │     DirectionsClient   one Google Maps Directions call, caches maneuvers
        │     Bearing            pure geometry: haversine, relative bearing, quadrant
        │
        ├── Sensors/
        │     LocationService    CLLocationManager: GPS + true heading (port from probe)
        │     MotionService      CMMotionManager: accel + gyro at 50 Hz (port from probe)
        │
        ├── Networking/
        │     LC2Transmitter     actor: UDP socket + 100 ms heartbeat loop
        │     LC2Packet          codec: encode an event to bytes per docs/03-protocol.md
        │
        ├── Replay/
        │     RouteReplayer      feeds pre-recorded samples into RouteEngine for the demo
        │
        └── UI/
              ControlPanelView   status, route picker, live/replay toggle, packet log
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

The vision-danger packet (`0x10` in the architecture) originates on the Coral board, not the phone, so the phone never emits it. The app only needs to not collide with that opcode space.

## Build order during the hack

Aligns with the gates in `docs/07-timeline.md`. Each step is shippable on its own and de-risks the next.

1. **Port the two sensor services from the probe** and confirm heading and GPS read clean on the demo phone. This is already proven hardware, so it should be an hour, not a night.
2. **Stand up `LC2Transmitter` and `LC2Packet`** and fire a hardcoded turn-left packet at the ESP32 on the 100 ms heartbeat. Belt twitches on command. This proves the radio link before any routing exists.
3. **Build `Bearing` and `RouteEngine` against a hardcoded two-point route** with unit tests on the geometry. No Maps yet. Walk in a hallway, watch the staged event change.
4. **Add `RouteReplayer` and a recorded route.** This is the demo path. Get it solid before touching live Maps.
5. **Add `DirectionsClient`** for the live bonus. Falls back to the cached route on any failure.
6. **Polish `ControlPanelView`**: connection status, current cue, packet log, live/replay toggle. The operator UI follows the accessibility rules in `SWIFT.md`.

If time runs short, the cut line is after step 4. Replay demo plus a working belt is a complete story. Live Maps is the part the pitch can disclose as a stretch.

## What this app is not

- Not the belt firmware. The ESP32 turning events into PWM lives in a separate part of the repo once the stack lands.
- Not the vision tier. That is Coral-side, conditional, and described in `docs/05-vision-tier.md`.
- Not a general navigation app. It computes one thing: which quadrant to tap next. Everything else is in service of that.

## Open questions for the alignment meeting

- Confirm Swift over Expo. This plan assumes Swift. If the team picks Expo, the architecture carries over but the language and frameworks change.
- Confirm the UDP transport choice for the phone-to-ESP32 link matches what `docs/04-phone-side.md` lands on.
- Decide whether the recorded replay route is captured before the hack or during setup on Saturday.
