# Navigation + LiDAR avoidance handoff

Read `STATUS.md` first for the whole project. This doc covers one workstream: turn-by-turn
navigation, the LiDAR obstacle-avoidance safety layer, the live-GPS walk mode, the shared-session
camera, and the on-device debug log. It is the place to pick up that work without re-reading every
file.

**Last updated:** 2026-06-21
**Owner area:** `ios/Sources/Routing/`, `ios/Sources/Perception/ObstacleAvoidance.swift`,
`ios/Sources/Diagnostics/EventLog.swift`, the depth band sampling in `Sensors/DepthService.swift`,
and the navigation/avoidance parts of `AppModel.swift` + the Diagnostics UI.

## What works today

- **Navigation follows the real drawn path (pure pursuit).** `DirectionsClient` decodes Google's
  step polylines into a dense path; `RouteEngine` projects the wearer onto it, aims a look-ahead
  point a few meters ahead along the path, and emits a belt cue every tick. Straightaways read as a
  steady forward tap; sidewalk corners produce a turn as the look-ahead rounds them.
- **LiDAR obstacle avoidance.** Reads three depth bands and steers toward the open side, escalating
  to a stop only when the path ahead is blocked and neither side has room. Debounced so it does not
  chatter, and it switches sides dynamically when the other side is consistently clearer.
- **Live-GPS walk mode** for field testing, alongside the simulator and the bench slider.
- **One ARSession** drives the camera preview, the LiDAR depth, and the YOLO person tier together
  (the old second `AVCaptureSession` was removed).
- **On-device event log** in Diagnostics shows cue and avoidance transitions with the band values.

## Priority stack (the cue arbitration)

In `AppModel.tick()`, highest first. Each lower tier fires only when the ones above are quiet:

1. **Person in path** (camera / YOLO) — perception agent's tier.
2. **LiDAR obstacle avoidance** — this workstream.
3. **Early-warning heads-up** (pre-LiDAR looming) — perception agent's tier.
4. **Navigation** turn cue.
5. Idle.

Keep this order. Avoidance must stay above navigation and below the confirmed-person tier.

## Code map

- `Routing/Polyline.swift` — Google encoded-polyline decoder (pure, tested).
- `Routing/DirectionsClient.swift` — one walking-route call; returns the dense path (per-step
  polylines concatenated, overview then step-endpoints as fallback). Surfaces `error_message`.
- `Routing/DirectionsService.swift` — the cost governor (cache, coalesce, debounce, session/day
  caps, no retry). Only billed surface in the app. Do not loosen without server-side quota.
- `Routing/Bearing.swift` — pure geometry: bearings, distance, plus path projection
  (`closestPoint`) and look-ahead (`point(on:aheadOf:by:)`) for pure pursuit.
- `Routing/RouteEngine.swift` — holds the dense `path` + `pivots`; `updateRoute(...)` is the
  pure-pursuit follower; `remaining`/`distanceToNext` drive the banner. Bench `update(_:)` and
  `calibrate` are separate. `applyCalibration:` is false for the simulator (its heading is already
  body-forward) and true for live GPS / bench.
- `Routing/Maneuver.swift` — `GeoPoint`, `RouteMath` (pivots, remaining distance, ETA, the demo
  route).
- `Routing/RouteSimulator.swift` — virtual walker over the dense path.
- `Perception/ObstacleAvoidance.swift` — `ObstacleAvoidance.decide(...)` (pure, tested) +
  `AvoidanceFilter` (settle / hold / dynamic side-switch).
- `Sensors/DepthService.swift` — `bandedNearest(...)` produces the three bands; also publishes the
  shared `previewImage`. (Person tier + early-warning live here too, owned by the perception agent.)
- `Diagnostics/EventLog.swift` — deduped on-device log; `AppModel.events` records `avoid` and `cue`
  transitions; shown in `ControlPanelView` "Event log" and "Avoidance (LiDAR)" cards.
- `AppModel.swift` — owns the decide loop, the drive modes, `avoidanceCue()`, route loading,
  live-walk start/stop. Hot shared file (see coordination below).
- `CitrusSquadConfig.swift` — all the tuning knobs.

## Tuning knobs (`CitrusSquadConfig`)

- `lookAheadMeters` (8) — pure-pursuit look-ahead. Larger smooths and rounds corners sooner.
- `pivotThresholdDegrees` (25) — heading swing that counts as a corner for the banner.
- `pathArriveMeters` (4) — arrival radius at the destination.
- `onPathToleranceMeters` (= reroute deviation) — past this off-line distance, steer back to the line.
- `proximityThresholdMeters` (1.8) — LiDAR in-path detection range.
- `dangerNearMeters` (0.5) — danger range that forces a stop when boxed in.
- `avoidanceMinSideClearance` (1.0) — a side needs this much room to count as passable; below it on
  both sides with the path blocked means stop instead of steer.
- `obstacleSettleTicks` (2) / `obstacleHoldTicks` (3) — avoidance debounce on/off at 10 Hz.

## Open items / risks

- **VERIFY the left/right band mapping on device.** `bandedNearest` splits the depth buffer's rows
  (the scene's left-right in portrait, since the buffer is native landscape) and maps band 0 = right,
  band 2 = left for the `.right` camera orientation. This was derived, not yet confirmed on hardware.
  Test: Diagnostics → Avoidance (LiDAR), hold an obstacle on your left; the **L** band should drop
  and it should say **steer right**. If mirrored, swap the `left:`/`right:` in the `bandedNearest`
  return (the line is commented for exactly this) — a one-line flip.
- **Live-GPS nav is GPS-noise sensitive.** Pedestrian GPS drifts a few meters; the look-ahead and
  on-path tolerance absorb most of it. Tune `lookAheadMeters` / `onPathToleranceMeters` to the venue.
- **Demo route is hand-placed.** `RouteMath.demoRoute` is a straight line down Bancroft Way from
  outside the MLK Student Union; coordinates are approximate. For a road-snapped route, tap the map
  and Fetch (one governed Directions call, then cached).
- **Belt + LC2 round-trip unproven on hardware.** On-screen cue (Operate big word + Demo BeltView)
  is the faithful proxy until the ESP32 is wired.
- **This workstream's latest changes (band-orientation fix + dynamic side-switch) are uncommitted**
  in the working tree as of this writing. Build is clean, 77 tests pass.

## Build, run, test (device)

```sh
cd ios
xcodegen generate
xcodebuild -project CitrusSquad.xcodeproj -scheme CitrusSquad \
  -destination 'id=00008130-001929D91A06001C' -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages -allowProvisioningUpdates test
xcrun devicectl device install app --device 00008130-001929D91A06001C \
  build/Build/Products/Debug-iphoneos/CitrusSquad.app
xcrun devicectl device process launch --device 00008130-001929D91A06001C com.samuelgerungan.CitrusSquad
```

Device must be unlocked to launch. `generic/platform=iOS Simulator` with `build-for-testing` is a
fast compile check when the phone is not attached. No simulators are installed, so tests run on the
device.

## How to test the features

- **Navigation (desk):** Demo → Load demo route → Run sim. Cue holds Forward on the straightaway,
  turns at corners; banner counts down; Arrived at the end.
- **Navigation (field):** Calibrate facing forward → Load/fetch a route → Walk GPS, then walk it.
- **Avoidance:** Diagnostics → Start depth → point at obstacles. Watch the Avoidance card's bands
  and the Event log (`avoid` lines carry L/C/R + the decision). Confirm it steers to the open side
  and only stops when boxed in.
- **Priority:** run a route + start depth + point at a wall → avoidance preempts the turn cue, then
  hands back when clear.

## Multi-agent coordination

Three agents share `sam/ios-app-base`: this navigation/avoidance work, the perception early-warning
+ person tier, and the voice layer. `AppModel.swift`, `Sensors/DepthService.swift`, and
`UI/ControlPanelView.swift` are hot shared files. Re-read them before a deep edit; keep changes
file-disjoint where possible. Commits so far have sometimes been catch-all sweeps of the whole
working tree, so confirm with `git log`/`git status` what is already committed before assuming your
change is uncommitted. Pure logic (geometry, decide, filter, polyline) is unit-tested; keep it that
way.
