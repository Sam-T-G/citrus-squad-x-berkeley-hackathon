# WAND — phone-side iOS app

The Tier-2 brain of WAND. Reads heading and GPS, computes which belt quadrant to tap, and sends LC2 packets to the ESP32 over UDP. This is the base scaffold: the structure, the sensors, the link, and the navigation math are in place. Live Maps and route replay come next.

Built to the contract in [`../docs/11-phone-app-design-spec.md`](../docs/11-phone-app-design-spec.md) and the craft rules in [`../SWIFT.md`](../SWIFT.md).

## Requirements

- Xcode 16 or newer (Swift 6, the Observation framework, Swift Testing).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not committed.
- The demo phone: iPhone 15 Pro Max on iOS 27. Sensors and the LiDAR depth feed do not work in the simulator.

## Build and run

```sh
cd ios
xcodegen generate      # writes WAND.xcodeproj from Project.yml
open WAND.xcodeproj
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
├── WANDApp.swift          @main entry
├── AppModel.swift         @MainActor @Observable; wires services, runs the staging loop
├── WANDConfig.swift       tunable numbers in one place
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

## Notes

- The `.xcodeproj`, `DerivedData/`, and `xcuserdata/` are gitignored. Commit `Project.yml` and `Sources/`, not the generated project.
- Swift 6 strict concurrency is on. The build is warning-clean; keep it that way.
