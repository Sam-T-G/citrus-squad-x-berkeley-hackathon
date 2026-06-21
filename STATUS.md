# STATUS — living context and handoff

Read this first. It is the single source of truth for where the project is right now, so any agent (or teammate) can pick up without re-reading the whole repo. It is a living document: whoever lands meaningful work updates it in the same pass. The keep-current rule is at the bottom.

**Last updated:** 2026-06-21
**Branch:** `sam/ios-app-base` (ahead of `origin/sam/ios-app-base` by 4 commits, not yet pushed)
**Latest commit:** `3b699a3` Add sponsor, voice, bridge, and navigation handoff docs

**Heads-up on uncommitted work:** the working tree is now clean. Everything that was loose is committed: the early-warning tier wiring (`990a60e`), the `server/` belt-bridge fallback (`34a7c56`), and the sponsor/voice/bridge/navigation handoff docs (`3b699a3`), on top of the prior `1b7e948` (Voice layer, `Secrets`, `BearingTracker`, `EventLog`). These four commits are local-only; `git push` when ready to share with the team.

## TL;DR

Citrus Squad is a haptic navigation belt for blind and low-vision wearers. A chest-mounted iPhone reads Google Maps directions and the compass to tell the wearer which way to turn by tapping a four-servo belt, and reads its own LiDAR to warn when something is close ahead. The phone is the sensing and the brain; an ESP32 (or an Arduino-over-USB fallback) drives the servos. The phone-side iOS app is the active build. It compiles under Swift 6 strict concurrency, runs on the demo phone, and now includes a live Google Maps map, a draw-a-path walk mode with LiDAR avoidance, and a voice layer scaffold. "Citrus Squad" is a placeholder product name (it is the team name); a real product name will trigger another rename later.

## Current state at a glance

- **Stack:** native iOS Swift, locked at the alignment meeting. iOS 17 minimum, Swift 6 strict concurrency complete, XcodeGen for the project file.
- **Builds and runs** on the demo phone (iPhone 15 Pro Max, iOS 27 beta). Clean build, no concurrency warnings. ~120+ unit-test assertions across 10 test files, all passing.
- **Installed on the phone** as "Citrus Squad" (`com.samuelgerungan.CitrusSquad`), via a proven command-line build + install + launch flow.
- **Direction tier** (turn cues) and **proximity tier** (LiDAR obstacle, directional via three-band sampling) are wired through to the LC2 transmitter.
- **Live Google Maps + navigation** in the Demo tab: real my-location dot, route polyline, markers, camera follow, tap-to-set-destination, a turn-by-turn banner with local ETA, plus a draw-a-path walk mode that follows a hand-drawn route and folds in LiDAR avoidance.
- **Cue arbitration is a four-tier priority stack** (highest first, each tier fires only when the ones above are quiet): person-in-path (camera/YOLO) > LiDAR obstacle avoidance > early-warning heads-up (pre-LiDAR looming) > navigation turn cue > idle. Documented in `ios/NAVIGATION-HANDOFF.md`.
- **Early-warning tier wired** (staged): `BearingTracker` flags a centered, looming object before LiDAR has a return and emits a soft Front tap (`.earlyWarning` source on the vision-danger wire event, floored intensity, its own spoken line and a light haptic). Arbitrated below person and LiDAR so it never masks a real hazard.
- **Voice layer scaffolded** (`Voice/`): Deepgram Voice Agent session actor, client-side function calling, place resolver, push-to-talk. Builds clean for simulator. Not yet run on the phone.
- **Belt-bridge fallback built** (`server/`, untracked): a laptop FastAPI server that takes the phone's LC2 stream over WebSocket and forwards it to an Arduino Uno over USB serial, for the case where the ESP32 does not come up.
- **Not yet proven on hardware:** the belt itself (servo PWM), the LC2 round-trip to a real ESP32 or the Arduino bridge, LiDAR behavior at the chest-mount angle, combined load + thermals, and the voice layer on-device.

## Locked decisions

These are settled. Do not reopen without Sam.

- **Native iOS Swift** is the stack.
- **Phone owns all sensing.** Direction (Maps + compass), proximity (LiDAR), and person-in-path (camera, stretch). The ESP32 is the actuator only.
- **Coral is dropped from the base**, kept only as an optional sponsor-angle stretch. The phone LiDAR/camera covers the safety story. See `docs/05-vision-tier.md`.
- **Safety beats direction.** The phone is the single LC2 sender and arbitrates: an active hazard preempts the turn cue for that heartbeat, one packet per tick. See `docs/12-perception-and-safety-design.md` §4.
- **Hazard tap means "obstacle is on this side,"** matching the turn-cue convention.
- **LC2 events:** `0x20` turn-slight, `0x21` turn-now, `0x22` turn-around, `0x23` arrived, `0x40` obstacle-near (LiDAR, base), `0x10` vision-danger (camera stretch or Coral), `0x00` idle. New event `0x40` reuses the sustained tap-train pattern, so the four-pattern cap holds. See `docs/03-protocol.md`.
- **Replay/sim-first demo.** The demo drives off a cached or simulated route, not live GPS. Live Maps and the draw-a-path walk are bonuses.
- **Sponsor talk/think tiers:** Deepgram (Voice Agent) for ears and mouth, Claude for reasoning, Fetch.ai as an optional transactional tier. No sponsor integration touches the LiDAR obstacle reflex. See `docs/13`, `docs/14`.

## Architecture snapshot

```
iPhone (Citrus Squad app)                         ESP32 (belt)  [or Arduino-over-USB bridge]
  Maps directions + compass  -> turn cue            receives one LC2 packet
  LiDAR scene depth          -> obstacle cue        per 100 ms heartbeat,
  camera Vision (stretch)    -> person cue          renders the event as a
  voice (Deepgram + Claude)  -> spoken layer         servo pattern, falls
        |                     (off the safety path)   quiet after 500 ms silence
        v  arbitrate (safety > direction)
  one LC2 packet / 100 ms  --UDP over Wi-Fi-->  4 servos: Far L, L, R, Far R
```

LC2 is a 4-byte wire format: event, quadrant mask, intensity, sequence. Defined in `docs/03-protocol.md`. The optional laptop bridge re-frames each LC2 packet as a 6-byte serial frame (0xA5 sync + 4 LC2 bytes + XOR checksum) for the Arduino. See `docs/15` and `server/README.md`.

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
- **Signing:** Apple Development cert for `samuelgerungan@gmail.com`, team `8K9T7N9LHM`. Free-tier window covers the hack (cert expires June 26-27).
- **Keys:** Google Maps key (entered in Diagnostics or stored), Deepgram + Anthropic keys pasted into `ios/Local.xcconfig` (gitignored, injected through Info.plist via `Secrets.swift`). Voice degrades to unavailable when keys are unset.
- **Tests:** `LC2PacketTests`, `RoutingTests`, `DepthHazardTests`, `DirectionsServiceTests`, `ObstacleAvoidanceTests`, `PersonDetectorTests`, `PersonFusionTests`, `BearingTrackerTests`, `PlaceResolverTests`, `VoiceCommandTests`. Run with `xcodebuild test` or ⌘U. The packet golden vectors and the geometry are the high-value ones.
- **The `.xcodeproj` and `build/` are gitignored.** Regenerate the project after pulling or adding files.

## Workstreams: done / in flight / next

**Done (committed on the branch):**
- Base app scaffold: app model, services, routing, networking, UI, tests.
- LC2 packet codec + UDP transmitter actor with the 100 ms heartbeat and sequence byte.
- Direction tier: bearing math, route engine, quadrant mapping, calibration, polyline decode.
- Proximity tier: ARKit LiDAR depth, three-band directional sampling, obstacle cue wired to `0x40` with safety-over-direction arbitration.
- LiDAR `ObstacleAvoidance` directive logic (clear / steer / stop) and a live-GPS walk mode.
- Cost-governed Google Directions client (caches, debounces, caps daily calls).
- Live Google Maps SDK map in the Demo tab: my-location dot, route polyline + markers, camera follow, tap-to-set-destination. Turn-by-turn banner with local remaining-distance and walking ETA. Draw-a-path walk that follows a hand-drawn route.
- Route simulator for a no-GPS bench/demo drive.
- Split UI: a production operator screen and a diagnostics console, plus Demo panels (camera, depth bars, map + nav).
- Thermal soak instrumentation (`ThermalMonitor` + soak card).
- Person tier code-complete and tested: YOLOv8n CoreML model bundled, `PersonDetector` (gate state machine) + `PersonFusion` (depth-crop math) ported from Cole's Python and unit-tested.
- ESP32 firmware sketch (AP mode default, servo pins, patterns).
- Full rename WAND -> Citrus Squad across code, firmware, docs, bundle id.

- **Voice layer** (`Voice/`, committed): Deepgram Voice Agent session actor with client-side function calling, `PlaceResolver` (presets + free MKLocalSearch), command mapping, push-to-talk model, hold-to-talk control, `Secrets.swift` xcconfig key injection. Builds clean for simulator under strict concurrency; pure command/resolver tests added. Deepgram wire-format bits flagged `VERIFY ON DEVICE`. Not yet run on the phone.
- **Early-warning logic** (`Perception/BearingTracker.swift`, `InterferenceStore.swift`, committed): pure constant-bearing + looming collision detection, unit-tested. The wiring into the belt arbitration is staged (see below).
- **Diagnostics `EventLog`** and one shared ARSession driving camera preview + LiDAR depth + YOLO together (the old second `AVCaptureSession` was removed).

- **Early-warning tier wiring** (`990a60e`): the `.earlyWarning` cue source, its soft Front tap / floored intensity / own spoken line / light haptic, and its slot below person and LiDAR in `AppModel.tick()`.
- **Belt-bridge server** (`server/`, `34a7c56`): FastAPI WebSocket-to-USB-serial gateway for the Arduino Uno fallback, with a health dashboard and a scripted test client.

**In flight / next:**
- **Push the branch.** Four local commits (`990a60e`, `34a7c56`, `3b699a3`, plus this STATUS) are not yet on origin. Push when ready to share.
- **Thermal soak run.** Instrumented but not yet run on the phone. Top open unknown. Procedure in `docs/12` §6 and the soak card.
- **Belt bring-up.** ESP32 + servos on the bench, then the live LC2 round-trip. The Arduino-over-USB bridge (`server/`) is the fallback if the ESP32 does not come up. Neither proven on hardware yet.
- **Person tier activation.** Code-complete and tested; wire `report()` into `AppModel` arbitration and reconcile the thermal gate, then prove on-device. See `ios/CV-PORT-PLAN.md`.
- **Voice V0 on the phone:** hold the button, see a live transcript; then V1 (one function round-trips). Keys go in `ios/Local.xcconfig`.
- **Live Maps on the demo phone.** Built and installed; enter the key in Diagnostics, then run the route or tap/draw a destination. Still want a real cached demo route captured ahead of judging.
- **Depth hardening:** ground-plane rejection at the mount angle, threshold tuning, false-positive discipline (settle / hysteresis / refractory) per `docs/12`.

## Code map (`ios/Sources/`)

- `CitrusSquadApp.swift` — `@main`; restores the stored Maps key before any map loads, shows `RootView`.
- `RootView.swift` — tabs: Production operator screen, Demo, Diagnostics, Control Panel.
- `AppModel.swift` — `@MainActor @Observable`. Owns the services, runs the 10 Hz decide loop, ranks person > avoidance > navigation, arbitrates hazard over turn, fans the resolved cue to the belt and any `CueSink`, dispatches voice commands, governs Directions calls.
- `CitrusSquadConfig.swift` — all tunable constants in one place.
- `Secrets.swift` — Deepgram/Anthropic keys from `Local.xcconfig` through Info.plist; `nil` when unset so voice degrades to unavailable. (Untracked.)
- `MapsBootstrap.swift` — hands the Google Maps SDK its API key once per launch (the same key Directions uses).
- `Routing/` — `Bearing` (pure geometry), `RouteEngine` + `QuadrantMapper` (quadrant + calibration + current cue), `Maneuver`/`RouteMath` (incl. remaining-distance / walking-ETA for the nav banner), `Polyline` (Google polyline decode), `RouteSimulator` (no-GPS drive), `DirectionsClient` + `DirectionsService` (Maps + cost caps).
- `Sensors/` — `LocationService` (heading + GPS), `MotionService` (50 Hz accel/gyro), `DepthService` (ARKit LiDAR, three-band; hosts the ARSession where vision detectors hook in; thermal gate).
- `Networking/` — `LC2Packet` (codec), `LC2Transmitter` (actor: UDP + heartbeat + sequence).
- `Perception/` — `Cues` (`ResolvedCue`, distance-graded intensity, `HazardSource`/`CueSink` protocols), `ObstacleAvoidance` (LiDAR clear/steer/stop), `PersonDetector` (YOLOv8n + gate) + `PersonFusion` (depth-crop math), `BearingTracker` + `InterferenceStore` (early-warning, untracked), `VisionHazardSource`, `DetectionStore`, `AudioCueSink`.
- `Voice/` (untracked) — `VoiceModel` (push-to-talk, `@Observable`), `VoiceSession` (actor: Deepgram Voice Agent socket + audio + client-side function calls), `VoiceAudio` (mic capture + TTS), `VoiceCommand` (function-name mapping), `PlaceResolver` (spoken name to coords), `VoiceControlView`, `VoiceError`. Off the safety path; see `docs/14`.
- `Diagnostics/` — `ThermalMonitor` (soak sampling), `EventLog` (deduped cue-transition log, untracked).
- `UI/` — `ProductionView`, `ControlPanelView`, `BeltView`, `Cards`, `Feedback`, and `Demo/` (`GoogleMapView`, `NavigationOverlay`, `MapSection`, `CameraPanel`, `DepthPanel`).

`firmware/citrus_squad_belt/` — the ESP32 Arduino sketch and `config.h` (Wi-Fi AP mode, servo pins, pattern timing).
`server/` — the laptop belt-bridge (FastAPI WebSocket -> USB serial to an Arduino Uno), the fallback path.
`cv/` + `tests/` — Cole's Python YOLOv8n + LiDAR depth-fusion pipeline (20 navigation classes, 17 tests). `server.py` re-exports the CV ingest app and adds a `/haptics` broadcast.

## Doc map (who owns what)

- `docs/00`–`02` — overview, architecture, hardware.
- `docs/03` — LC2 wire protocol. Source of truth for the bytes.
- `docs/04` — phone-side product behavior (heading math, calibration, milestones).
- `docs/05` — safety tier (phone perception; Coral as optional stretch).
- `docs/06`–`10` — failure modes, timeline, team roles, demo and pitch, validated capabilities.
- `docs/11` — phone-app build contract (the one decision function, bearing-to-bytes table, ownership of each tricky byte). Camera permission is required (ARKit depth uses the camera stack).
- `docs/12` — perception and safety design (LiDAR/camera, arbitration, demo and thermal hardening).
- `docs/13` — sponsor implementation menu (Deepgram, Anthropic, Fetch.ai, scored).
- `docs/14` — voice and reasoning plan (Deepgram Voice Agent + Claude, function contract, V0–V5).
- `docs/15` — belt-server bridge plan (Arduino-over-USB fallback if the ESP32 fails).
- `IOS-APP-PLAN.md` — module map and build order. `SWIFT.md` — craft rules. `HANDOFF.md` — the original implementation runbook (parts of its "where the base left off" section are historical; trust this STATUS for current state).
- `ios/CV-PORT-PLAN.md`, `ios/PERCEPTION-AVOIDANCE-HANDOFF.md`, `ios/PERCEPTION-EARLY-WARNING-PLAN.md`, `ios/YOLO-WORLD-PLAN.md` — perception/vision implementation plans (committed in `1b7e948`).
- `ios/NAVIGATION-HANDOFF.md` — the navigation + LiDAR-avoidance + live-GPS-walk + shared-camera + event-log workstream, including the four-tier cue arbitration. Untracked; add it to git.

## Open decisions and risks

- **A lot of work is uncommitted.** Single biggest housekeeping risk. Commit the Voice layer, server bridge, early-warning, and plan docs before anything else, so nothing is lost and teammates can see it.
- **ARKit vs AVFoundation for depth.** On ARKit now. Revisit after the thermal soak. AVFoundation depth runs cooler (skips world tracking). `docs/12` §5.
- **Thermal headroom is unproven.** The single biggest demo risk. Run the soak.
- **Belt and LC2 round-trip unproven on hardware.** Bench-test early. Bridge fallback ready if the ESP32 stalls.
- **Ground-plane false positives** from the chest-mount tilt will trip the obstacle cue if not handled. `docs/12` §5.
- **Motor layout mismatch.** `proposals/motor-layout-front-back-left-right.md` describes a Front/Left/Right/Back layout, while `docs/03` and `docs/11` still document Far Left/Left/Right/Far Right. Confirm which layout the app's masks actually use before belt integration, and reconcile the proposal or the protocol docs.
- **HANDOFF.md is stale on camera permission.** It advises dropping `NSCameraUsageDescription`; `docs/11` and `docs/12` supersede that (ARKit depth needs the camera permission). Fix the HANDOFF note when convenient.

## Multi-agent coordination

- Two agents share this working tree on `sam/ios-app-base`. Keep changes file-disjoint where possible.
- A Swift-implementation agent owns `ios/` code, `IOS-APP-PLAN.md`, and `docs/03`. A design/docs agent owns `docs/00`–`02`, `04`–`15`, `HANDOFF.md`, and this `STATUS.md`, and added the thermal soak instrumentation and ran the rename.
- Before a deep edit to a file the other agent is touching, re-read it first (it may have moved). If a spec is wrong, flag it here or in the PR, do not silently fork it in code.
- `wand-phone-probe` is a separate sibling repo (the proven sensor probe), not part of this rename. Leave those references alone.

## Session log

- **2026-06-20** — Stack confirmed Swift. Base app scaffolded and compiling. LiDAR folded into the base as the safety tier; Coral dropped to optional stretch. Design docs `11` and `12` added; canon docs (`00`–`10`, `IOS-APP-PLAN`) reconciled to the phone-perception architecture. `0x40 obstacle-near` added and made directional (three-band). Cost-capped Directions, route simulator, split production/diagnostics UI. Thermal soak instrumentation added; soak not yet run. Full rename WAND -> Citrus Squad across code, firmware, docs, and bundle id; app reinstalled on the phone under the new name.
- **2026-06-20** — Added a live Google Maps SDK map and a client-side navigation element to the Demo tab. Researched Maps Platform pricing first: rendering a native map and the my-location dot is free, so the only billed surface stays the one governed Directions call. Avoided the paid Navigation SDK and Geocoding/Places (destination is typed `lat,lng` or a free map tap). New files: `MapsBootstrap`, `UI/Demo/GoogleMapView`, `NavigationOverlay`, `MapSection`; `RouteMath` gained remaining-distance + ETA helpers (unit-tested). GoogleMaps added via SPM in `Project.yml`. README cost-control section hardened.
- **2026-06-20** — Sponsor strategy plus the voice layer scaffold. Picked Deepgram (Voice Agent) and Claude as the talk and think tiers, with Fetch.ai optional (`docs/13`, `docs/14`). Found two things the voice design assumed wrong (routing only took `lat,lng`; camera tools conflict with ARKit LiDAR) and resolved both (added `PlaceResolver`, dropped camera tools). Landed `Voice/`, `Secrets.swift` with xcconfig key injection, and the microphone permission. Builds clean for simulator; added pure tests for command mapping and the preset resolver. Deepgram wire-format details flagged `VERIFY ON DEVICE`.
- **2026-06-20** — Committed path-following with a hand-drawn route, LiDAR `ObstacleAvoidance` (clear/steer/stop), and a live-GPS walk mode (commit `15b8ee9`). Built the `server/` belt-bridge fallback (FastAPI WebSocket -> Arduino USB serial) and the early-warning `BearingTracker`. Full audit done: this STATUS refreshed to the real branch state. Found STATUS was 2 commits behind (it cited `206edea`, now an ancestor of HEAD) and under-described a large uncommitted body (Voice layer, server bridge, early-warning, `EventLog`, plan docs `13`–`15`, and the `ios/*-PLAN` docs). Flagged the motor-layout mismatch and the stale HANDOFF camera note. Next: commit the uncommitted work, then run the thermal soak and bench the belt.
- **2026-06-21** — Committed and pushed the loose body from the prior audit in `1b7e948` (Voice layer, `Secrets`, `BearingTracker`, `InterferenceStore`, `EventLog`, perception plan docs); branch is now in sync with origin. Wired the early-warning tier into the four-tier cue arbitration (person > LiDAR avoidance > early-warning > navigation): added the `.earlyWarning` cue source with a soft Front tap, floored intensity, its own spoken advisory line, and a light haptic, slotted below person and LiDAR so it never masks a real hazard. Added `ios/NAVIGATION-HANDOFF.md` for the navigation + avoidance workstream. Re-audited and refreshed this STATUS, then committed everything that was loose: the early-warning tier (`990a60e`), the `server/` belt-bridge (`34a7c56`), and the sponsor/voice/bridge/navigation docs (`3b699a3`). Working tree clean; four commits sit local-only ahead of origin. Next: push the branch, run the thermal soak, and bench the belt before judging.
- **2026-06-21** — Audited the YOLO/CV recognition surface and generalized the on-device vision tier from person-only to multi-class (`YOLO-WORLD-PLAN.md` path A). Added `CitrusSquadConfig.visionNavigationClasses` (the 20-class set, in lockstep with `cv/detection.py` `NAVIGATION_CLASSES`), swapped `PersonDetector.isPerson` for a `navigationLabel` class-set filter, and carried the real COCO label through `PersonDetection` and the overlay instead of the hardcoded `"person"`. The gate, depth fusion, and intensity math are untouched (they key on distance and side, not class), so safety behavior is unchanged; the win is real labels for the overlay, diagnostics, and the spoken tier, and the `BearingTracker` early-warning layer now distinguishes object types instead of only people. Builds clean for device; `PersonDetectorTests` (pure `decide` timing) unaffected. Then added `parking meter` to both the Swift and Python class sets (21 classes now). Next: optionally add `handbag`/`train` (COCO-native, to both lists); the heavier YOLO-World swap stays behind its three thermal/export/on-device gates.

## Keeping this current (the rule)

Any agent that lands meaningful work updates this file in the same pass, before the work is considered done:

1. Bump **Last updated** and **Latest commit**.
2. Move items between **done / built-but-uncommitted / in flight / next** as they change.
3. Update **locked decisions** if one landed, and **open decisions** if one resolved.
4. Append one line to the **session log**: date, what landed, what is next.

This file is the entry point. If it is stale, the next agent plans against the wrong state. Treat keeping it honest as part of the work, not an afterthought.
