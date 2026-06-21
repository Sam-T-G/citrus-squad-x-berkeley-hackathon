# Tolerance handoff: fine-tuning the navigation turn cue

This is the runbook for tuning the resistance on the belt's turn-by-turn cue. The base mechanism is built, tested, and on the phone. What is left is dialing in the numbers against how the belt actually feels on a walk. Read this first, then tune.

**Branch:** `sam/ios-app-base`
**Landed in:** `6e9794b` Add hysteresis and dwell to the navigation turn cue so the belt stops chattering
**Date written:** 2026-06-21

## The problem this solves

The turn cue used to be recomputed from the live heading every 100 ms against hard band boundaries. When the relative bearing sat near an edge (for example right around the 10 degree line between "on course" and "slight right"), normal heading jitter flipped the servo cue between two adjacent motors every single tick. On the belt that reads as all the taps darting back and forth next to each other.

The wearer wants steady guidance that resists small wobble, but still reacts fast when a real turn or a hazard shows up.

## What is built

A small state machine, `NavigationCueSmoother`, sits between the bearing math and the cue. It adds two layers of resistance, both navigation-only:

1. **Boundary hysteresis.** The band the belt is currently holding gets widened by a margin before the cue is allowed to leave it. A bearing that only dithers across a boundary holds the current tap. The wide rear (turn-around) band gets a larger margin than the adjacent boundaries.
2. **Dwell.** Once the bearing genuinely crosses past the widened band, the new band has to persist for a few ticks before the belt commits to it. A one-frame heading spike gets swallowed. A real, sustained turn still commits in a few hundred milliseconds.

The first reading after a reset commits immediately, so the belt is correct from the first tick instead of holding a stale cue. The smoother resets on a new route, on arrival, and when the wearer goes off-path.

### Why hazards are not affected

The smoother only touches the route-following turn cue. In `AppModel.tick()` the hazard tiers (a person in the path, then the LiDAR obstacle-avoidance layer) preempt navigation and keep their own fast response. The LiDAR avoidance layer already has its own safety-tuned debounce. So when a collision is imminent the belt still fires right away. The resistance only ever applies to the gentle steering underneath. Do not move the smoothing up into the hazard path while tuning.

## Files to know

- `ios/Sources/Routing/NavigationCueSmoother.swift` - the state machine. `update(relativeBearing:)` is the whole thing. Pure value type, deterministic, easy to test by replaying a bearing sequence.
- `ios/Sources/Routing/RouteEngine.swift` - holds `QuadrantMapper` (now band data plus a margin-aware `contains`) and owns a `turnSmoother`. The smoother is wired into `updateRoute` only. The bench `update(phoneHeading:)` path stays raw on purpose, so the Nav bench card in Diagnostics shows the unfiltered heading-to-cue mapping.
- `ios/Sources/CitrusSquadConfig.swift` - the knobs (below).
- `ios/Tests/RoutingTests.swift` - `QuadrantMapperTests` (the unchanged M4 table plus band/margin checks) and `NavigationCueSmootherTests` (jitter holds the cue, a single-frame spike is rejected, a sustained turn commits after the dwell).

## The knobs

All three live in `CitrusSquadConfig.swift`.

- `navCueDwellTicks` (currently `3`) - consecutive 10 Hz ticks a new band must persist before the belt switches. 3 is about 300 ms. Lower is snappier and more sensitive. Higher is steadier and laggier.
- `hysteresisAdjacentDegrees` (currently `5.0`) - the deadband margin on the normal band boundaries. Bigger means the bearing has to overshoot a boundary by more before the cue changes. This is the main lever for the side-to-side chatter.
- `hysteresisTurnAroundDegrees` (currently `10.0`) - the deadband margin on the wide rear turn-around band only.

Rough mental model while tuning:

- Belt still chatters between adjacent taps -> raise `hysteresisAdjacentDegrees` first (try 7 or 8), then raise `navCueDwellTicks`.
- Belt feels sluggish or laggy to start a real turn -> lower `navCueDwellTicks` (try 2), then lower `hysteresisAdjacentDegrees`.
- The U-turn cue flickers in and out at the back -> raise `hysteresisTurnAroundDegrees`.

Change one knob at a time so you can tell what did what.

## How to build, test, run

From `ios/`:

```sh
xcodegen generate
# build for the phone
xcodebuild -project CitrusSquad.xcodeproj -scheme CitrusSquad \
  -destination 'id=00008130-001929D91A06001C' -derivedDataPath build \
  -allowProvisioningUpdates build
# run only the routing tests on the phone (no simulator is installed on this Mac)
xcodebuild -project CitrusSquad.xcodeproj -scheme CitrusSquad \
  -destination 'id=00008130-001929D91A06001C' -derivedDataPath build \
  -allowProvisioningUpdates \
  -only-testing:CitrusSquadTests/NavigationCueSmootherTests \
  -only-testing:CitrusSquadTests/QuadrantMapperTests test
# install + launch
xcrun devicectl device install app --device 00008130-001929D91A06001C \
  build/Build/Products/Debug-iphoneos/CitrusSquad.app
xcrun devicectl device process launch --device 00008130-001929D91A06001C \
  com.samuelgerungan.CitrusSquad
```

Device id `00008130-001929D91A06001C` is Sam's iPhone. Launch needs it unlocked. The Mac has no iOS simulators, so tests run on the phone.

## How to tune on the phone

Two ways to drive the cue without walking outside:

1. **Nav bench (raw, no smoothing).** Diagnostics tab, Nav bench card. Calibrate forward, then drag the target bearing slider. This shows the raw band mapping, so use it to confirm the boundaries, not the smoothing.
2. **Sim or live walk (smoothed, this is what to tune).** Diagnostics tab, Navigation card. Load demo route, then Run sim, or Walk (live GPS) outside. The smoother is in this path. Watch the four-dot belt indicator on the Demo tab and the live cue on the status bar while the heading wobbles.

For the real feel, put the phone on the chest mount and walk the route with the belt on. The chest mount adds its own heading noise, which is exactly what the resistance is fighting. Numbers that feel right on the bench can feel wrong on the body.

Each change is a config edit, then `xcodegen generate` is not needed for a pure source edit, just rebuild, reinstall, relaunch.

## Open questions to resolve tomorrow

- Is a flat dwell right, or should a jump of two or more bands (a real sharp correction) commit faster than a one-band nudge? Right now every band change waits the same dwell. Escalation-aware dwell is the obvious next idea if turns feel slow but small wobble still leaks through.
- Should the input bearing get a light low-pass filter on top of the output smoothing, or does the band plus dwell cover it? Adding input smoothing is a separate lever and may double-count.
- Live GPS course is noisy at low walking speed. Check whether the resistance is enough there, or whether the heading source itself needs attention (see `resolveLiveHeading` in `AppModel`).
- Confirm the margins still feel right after any chest-mount calibration-on-start work lands, since that changes the body-heading zero.

## Definition of done

- On a chest-mounted walk, the belt holds a steady tap on a straightaway and does not flick between adjacent motors on normal sway.
- A real turn still engages within a beat, not a noticeable lag.
- A hazard still preempts instantly (unchanged, but sanity-check it while tuning).
- Final numbers written back into `CitrusSquadConfig.swift` with a one-line note on why, and `STATUS.md` session log updated.

## Guardrails

- Keep all smoothing in `NavigationCueSmoother` and `RouteEngine.updateRoute`. Do not add resistance to the person or LiDAR tiers.
- Keep `QuadrantMapper.cue(forRelativeBearing:)` returning the same table values. The M4 gate tests depend on it.
- If you change the smoother logic, update `NavigationCueSmootherTests` in the same pass and run them on the phone before committing.
- This tree is shared with another agent. Stage only the files you touched. Do not sweep in `Info.plist`, `HeadingCalibrator.swift`, or anything else you did not change.
