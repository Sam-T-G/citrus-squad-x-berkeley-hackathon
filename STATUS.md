# STATUS — living context and handoff

Read this first. It is the single source of truth for where the project is right now, so any agent (or teammate) can pick up without re-reading the whole repo. It is a living document: whoever lands meaningful work updates it in the same pass. The keep-current rule is at the bottom.

**Last updated:** 2026-06-20
**Branch:** `sam/ios-app-base`
**Latest commit:** `206edea` Make the LiDAR obstacle cue directional (three-band sampling)

## TL;DR

Citrus Squad is a haptic navigation belt for blind and low-vision wearers. A chest-mounted iPhone reads Google Maps directions and the compass to tell the wearer which way to turn by tapping a four-servo belt, and reads its own LiDAR to warn when something is close ahead. The phone is the sensing and the brain; an ESP32 drives the servos. The phone-side iOS app is the active build. The base scaffold compiles under Swift 6 strict concurrency and runs on the demo phone. "Citrus Squad" is a placeholder product name (it is the team name); a real product name will trigger another rename later.

## Current state at a glance

- **Stack:** native iOS Swift, locked at the alignment meeting. iOS 17 minimum, Swift 6 strict concurrency complete, XcodeGen for the project file.
- **Builds and runs** on the demo phone (iPhone 15 Pro Max, iOS 27 beta). Clean build, no concurrency warnings.
- **Installed on the phone** as "Citrus Squad" (`com.samuelgerungan.CitrusSquad`), via a proven command-line build + install + launch flow.
- **Direction tier** (turn cues) and **proximity tier** (LiDAR obstacle, now directional via three-band sampling) are wired through to the LC2 transmitter.
- **Not yet proven on hardware:** the belt itself (servo PWM), the LC2 round-trip to a real ESP32, LiDAR behavior at the chest-mount angle, and combined load + thermals.

## Locked decisions

These are settled. Do not reopen without Sam.

- **Native iOS Swift** is the stack.
- **Phone owns all sensing.** Direction (Maps + compass), proximity (LiDAR), and person-in-path (camera, stretch). The ESP32 is the actuator only.
- **Coral is dropped from the base**, kept only as an optional sponsor-angle stretch. The phone LiDAR/camera covers the safety story. See `docs/05-vision-tier.md`.
- **Safety beats direction.** The phone is the single LC2 sender and arbitrates: an active hazard preempts the turn cue for that heartbeat, one packet per tick. See `docs/12-perception-and-safety-design.md` §4.
- **Hazard tap means "obstacle is on this side,"** matching the turn-cue convention.
- **LC2 events:** `0x20` turn-slight, `0x21` turn-now, `0x22` turn-around, `0x23` arrived, `0x40` obstacle-near (LiDAR, base), `0x10` vision-danger (camera stretch or Coral), `0x00` idle. New event `0x40` reuses the sustained tap-train pattern, so the four-pattern cap holds. See `docs/03-protocol.md`.
- **Replay/sim-first demo.** The demo drives off a cached or simulated route, not live GPS. Live Maps is a bonus.

## Architecture snapshot

```
iPhone (Citrus Squad app)                         ESP32 (belt)
  Maps directions + compass  -> turn cue            receives one LC2 packet
  LiDAR scene depth          -> obstacle cue        per 100 ms heartbeat,
  camera Vision (stretch)    -> person cue          renders the event as a
        |                                            servo pattern, falls
        v  arbitrate (safety > direction)            quiet after 500 ms silence
  one LC2 packet / 100 ms  --UDP over Wi-Fi-->  4 servos: Far L, L, R, Far R
```

LC2 is a 4-byte wire format: event, quadrant mask, intensity, sequence. Defined in `docs/03-protocol.md`.

## Build, run, and device state

- **Build + install + launch from the CLI** (no Xcode GUI needed after the one-time Apple ID sign-in):
  ```sh
  cd ios
  xcodegen generate
  xcodebuild -project CitrusSquad.xcodeproj -scheme CitrusSquad \
    -destination 'id=00008130-001929D91A06001C' -derivedDataPath build \
    -allowProvisioningUpdates build
  xcrun devicectl device install app --device 00008130-001929D91A06001C \
    build/Build/Products/Debug-iphoneos/CitrusSquad.app
  xcrun devicectl device process launch --device 00008130-001929D91A06001C \
    com.samuelgerungan.CitrusSquad
  ```
  Device id `00008130-001929D91A06001C` is Sam's iPhone. Launch needs the phone unlocked.
- **Signing:** Apple Development cert for `samuelgerungan@gmail.com`, team `8K9T7N9LHM`. Free-tier window covers the hack.
- **Tests:** `LC2PacketTests`, `RoutingTests`, `DepthHazardTests`, `DirectionsServiceTests`. Run with `xcodebuild test` or ⌘U. The packet golden vectors and the geometry are the high-value ones.
- **The `.xcodeproj` and `build/` are gitignored.** Regenerate the project after pulling or adding files.

## Workstreams: done / in flight / next

**Done (on the branch):**
- Base app scaffold: app model, services, routing, networking, UI, tests.
- LC2 packet codec + UDP transmitter actor with the 100 ms heartbeat and sequence byte.
- Direction tier: bearing math, route engine, quadrant mapping, calibration.
- Proximity tier: ARKit LiDAR depth, three-band directional sampling, obstacle cue wired to `0x40` with safety-over-direction arbitration.
- Cost-governed Google Directions client (caches, debounces, caps daily calls).
- Route simulator for a no-GPS bench/demo drive.
- Split UI: a production operator screen and a diagnostics console.
- Thermal soak instrumentation (`ThermalMonitor` + soak card).
- ESP32 firmware sketch (AP mode default, servo pins, patterns).
- Full rename WAND -> Citrus Squad across code, firmware, docs, bundle id.

**In flight / next:**
- **Thermal soak run.** Instrumented but not yet run on the phone. Top open unknown. Procedure in `docs/12` §6 and the soak card.
- **Belt bring-up.** ESP32 + servos on the bench, then the live LC2 round-trip. Not yet done on hardware.
- **Camera person-in-path stretch** (`0x10`, on-device Vision gated by LiDAR distance). Designed, not built.
- **Live Maps key** entry and a real cached demo route.
- **Depth hardening:** ground-plane rejection at the mount angle, threshold tuning, false-positive discipline (settle / hysteresis / refractory) per `docs/12`.

## Code map (`ios/Sources/`)

- `CitrusSquadApp.swift` — `@main`, shows `RootView`.
- `RootView.swift` — selects the production operator screen vs the diagnostics console.
- `AppModel.swift` — `@MainActor @Observable`. Owns the services, runs the 10 Hz decide loop, arbitrates hazard over turn, fans the resolved cue to the belt and any `CueSink`.
- `CitrusSquadConfig.swift` — all tunable constants in one place.
- `Routing/` — `Bearing` (pure geometry), `RouteEngine` (quadrant + calibration + current cue), `Maneuver`, `RouteSimulator` (no-GPS drive), `DirectionsClient` + `DirectionsService` (Maps + cost caps).
- `Sensors/` — `LocationService` (heading + GPS), `MotionService` (50 Hz), `DepthService` (ARKit LiDAR, three-band).
- `Networking/` — `LC2Packet` (codec), `LC2Transmitter` (actor: UDP + heartbeat + sequence).
- `Perception/` — `Cues` (`ResolvedCue`, distance-graded intensity), `VisionHazardSource` (camera stretch), `AudioCueSink`, and the `HazardSource` / `CueSink` protocols that make sources and sinks pluggable.
- `Diagnostics/` — `ThermalMonitor` (soak sampling).
- `UI/` — `ProductionView`, `ControlPanelView`, `Cards`.

`firmware/citrus_squad_belt/` — the ESP32 Arduino sketch and `config.h` (Wi-Fi AP mode, servo pins, pattern timing).

## Doc map (who owns what)

- `docs/00`–`02` — overview, architecture, hardware.
- `docs/03` — LC2 wire protocol. Source of truth for the bytes.
- `docs/04` — phone-side product behavior (heading math, calibration, milestones).
- `docs/05` — safety tier (phone perception; Coral as optional stretch).
- `docs/06`–`10` — failure modes, timeline, team roles, demo and pitch, validated capabilities.
- `docs/11` — phone-app build contract (the one decision function, bearing-to-bytes table, ownership of each tricky byte).
- `docs/12` — perception and safety design (LiDAR/camera, arbitration, demo and thermal hardening).
- `IOS-APP-PLAN.md` — module map and build order. `SWIFT.md` — craft rules. `HANDOFF.md` — the original implementation runbook (some of its "where the base left off" section is now historical; trust this STATUS for current state).

## Open decisions and risks

- **ARKit vs AVFoundation for depth.** On ARKit now. Revisit after the thermal soak. AVFoundation depth runs cooler (skips world tracking). `docs/12` §5.
- **Thermal headroom is unproven.** The single biggest demo risk. Run the soak.
- **Belt and LC2 round-trip unproven on hardware.** Bench-test early.
- **Ground-plane false positives** from the chest-mount tilt will trip the obstacle cue if not handled. `docs/12` §5.

## Multi-agent coordination

- Two agents share this working tree on `sam/ios-app-base`. Keep changes file-disjoint where possible.
- A Swift-implementation agent owns `ios/` code, `IOS-APP-PLAN.md`, and `docs/03`. A design/docs agent owns `docs/00`–`02`, `04`–`12`, `HANDOFF.md`, and this `STATUS.md`, and added the thermal soak instrumentation and ran the rename.
- Before a deep edit to a file the other agent is touching, re-read it first (it may have moved). If a spec is wrong, flag it here or in the PR, do not silently fork it in code.
- `wand-phone-probe` is a separate sibling repo (the proven sensor probe), not part of this rename. Leave those references alone.

## Session log

- **2026-06-20** — Stack confirmed Swift. Base app scaffolded and compiling. LiDAR folded into the base as the safety tier; Coral dropped to optional stretch. Design docs `11` and `12` added; canon docs (`00`–`10`, `IOS-APP-PLAN`) reconciled to the phone-perception architecture. `0x40 obstacle-near` added and made directional (three-band). Cost-capped Directions, route simulator, split production/diagnostics UI. Thermal soak instrumentation added; soak not yet run. Full rename WAND -> Citrus Squad across code, firmware, docs, and bundle id; app reinstalled on the phone under the new name.

## Keeping this current (the rule)

Any agent that lands meaningful work updates this file in the same pass, before the work is considered done:

1. Bump **Last updated** and **Latest commit**.
2. Move items between **done / in flight / next** as they change.
3. Update **locked decisions** if one landed, and **open decisions** if one resolved.
4. Append one line to the **session log**: date, what landed, what is next.

This file is the entry point. If it is stale, the next agent plans against the wrong state. Treat keeping it honest as part of the work, not an afterthought.
