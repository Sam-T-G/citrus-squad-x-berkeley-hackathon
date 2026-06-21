# Citrus Squad — phone-side iOS app

The Tier-2 brain of Citrus Squad. Reads heading and GPS, computes which belt quadrant to tap, and sends LC2 packets to the ESP32 over UDP. This is the base scaffold: the structure, the sensors, the link, and the navigation math are in place. Live Maps and route replay come next.

Built to the contract in [`../docs/11-phone-app-design-spec.md`](../docs/11-phone-app-design-spec.md) and the craft rules in [`../SWIFT.md`](../SWIFT.md).

## Requirements

- Xcode 16 or newer (Swift 6, the Observation framework, Swift Testing).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not committed.
- The demo phone: iPhone 15 Pro Max on iOS 27. Sensors and the LiDAR depth feed do not work in the simulator.

## Build and run

```sh
cd ios
xcodegen generate      # writes CitrusSquad.xcodeproj from Project.yml
open CitrusSquad.xcodeproj
```

Then in Xcode: pick the demo phone as the run destination, set Signing to your personal team if needed, and press ⌘R. Grant the location, motion, and camera prompts on first launch.

Run the unit tests with ⌘U. They cover the LC2 packet byte layout and the navigation geometry, which are pure and do not need the device.

## What the screen does

One card per subsystem:

- **Belt link.** Set the ESP32 host and port, start the link, and watch packets count up. "Send test cue" fires one known packet so you can confirm the belt reacts. This is the M0 check.
- **Nav bench.** Calibrate forward, set a target route bearing with the slider, then rotate the phone and watch the cue change. This drives the full heading-to-cue path without GPS or Maps.
- **Heading, GPS, Motion.** Live sensor readouts, ported from the proven `wand-phone-probe`.
- **Depth (LiDAR).** Nearest obstacle distance straight ahead, and whether it is within the threshold. Sensing only for now; emitting it to the belt is an open team decision.

## Layout

```
Sources/
├── CitrusSquadApp.swift          @main entry
├── AppModel.swift         @MainActor @Observable; wires services, runs the staging loop
├── CitrusSquadConfig.swift       tunable numbers in one place
├── Routing/
│   ├── Bearing.swift      pure geometry: haversine, body and relative bearing
│   └── RouteEngine.swift  QuadrantMapper + calibration + current cue
├── Sensors/
│   ├── LocationService.swift   heading + GPS
│   ├── MotionService.swift     accel + gyro at 50 Hz
│   └── DepthService.swift      ARKit LiDAR scene depth
├── Networking/
│   ├── LC2Packet.swift     the 4-byte wire format
│   └── LC2Transmitter.swift  actor: UDP socket + 100 ms heartbeat
└── UI/
    ├── ControlPanelView.swift
    └── Cards.swift
Tests/
├── LC2PacketTests.swift    golden vectors against docs/03
└── RoutingTests.swift      geometry + quadrant table against docs/04
```

## Cost control (Maps API)

The app shows a live Google map in the Demo tab and fetches walking routes from Google. Of those, **only the Directions route fetch is billed.** Rendering the map, the blue my-location dot, the camera follow, the route line and markers, the tap-to-set-destination, and the navigation banner are all free: the Maps SDK for iOS does not charge per map load on mobile, and the my-location dot reads CoreLocation locally with no API call. Everything else (the belt link, the sensors, the simulator) is local and free too. So the one paid surface is the same as before, and it stays governed.

**What we deliberately do NOT use** (each is a separate paid API): Geocoding, Places / address autocomplete, the Routes API, and the Navigation SDK. The destination is set by typing `lat,lng` or tapping the map, so no geocoding is ever called. Keep it that way.

**Client side, in `DirectionsService`:**

- **Result cache.** Routes are cached by rounded coordinates and persisted across launches, so an identical route never hits the network twice. The demo route is fetched at most once, ever.
- **In-flight coalescing.** Concurrent requests for the same route share one call.
- **Debounce.** A minimum interval between live calls stops double-taps and tight loops.
- **Hard caps.** Per-session and per-day call ceilings. Once hit, calls are refused, not queued.
- **No automatic retries.** A failure never silently re-spends; you re-trigger by hand.

The Maps section of the diagnostics screen shows calls this session, calls today, cache hits, and cached routes, plus a "Clear route cache" button. The caps live in `DirectionsService.Policy`. One key powers both the map and the Directions call; enable both on it.

**Server side, in Google Cloud (do this, it is the real backstop):** client guards do not protect a key that someone copies. "You are financially responsible for charges caused by abuse of unrestricted API keys." Set these once in the Cloud console:

1. **Restrict the key by application** to iOS apps and this app's bundle id (`com.samuelgerungan.CitrusSquad`).
2. **Restrict the key by API** to exactly two: **Maps SDK for iOS** and **Directions API**. Leave Geocoding, Places, Routes, and Navigation SDK off, so a stray call to a paid extra fails instead of billing.
3. **Set a daily quota** on the Directions API (APIs & Services → Directions API → Quotas). A few hundred requests a day is plenty for the hack and caps the worst case. The Maps SDK needs no quota cap because mobile map loads are not billed.
4. **Set a billing budget and alert** (Billing → Budgets & alerts), for example $5–$10, so you get an email well before any real spend.

A key with no quota is what runs up a bill. The quota is the guarantee; the client guards just keep normal use cheap. Because map rendering is free, the map view is safe to leave on for the whole demo.

## Notes

- The `.xcodeproj`, `DerivedData/`, and `xcuserdata/` are gitignored. Commit `Project.yml` and `Sources/`, not the generated project.
- Swift 6 strict concurrency is on. The build is warning-clean; keep it that way.
- The Maps API key is entered in the app and stored in `UserDefaults`. It is never committed.
