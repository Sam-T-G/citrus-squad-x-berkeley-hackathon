# Perception Early-Warning Plan

A monocular, depth-free layer that flags an obstacle before LiDAR can see it. It watches for an
object that holds the wearer's heading across frames and grows in the frame, and fires a soft
heads-up while there is still room to react. This buys lead time the depth tiers cannot, because they
do not exist until LiDAR returns.

**Owner:** Sam (iOS lane, all Swift).

## Read order

1. This file. The signal, where it plugs in, and the build order.
2. [`PERCEPTION-AVOIDANCE-HANDOFF.md`](PERCEPTION-AVOIDANCE-HANDOFF.md) for the detection and
   collision layers this sits above, and the safety-over-direction arbitration it must respect.
3. [`../docs/12-perception-and-safety-design.md`](../docs/12-perception-and-safety-design.md) §4 for
   the safety-over-direction rule and §6 for the settle / hysteresis discipline the cue follows.

## The gap this fills

Every "is this closing on me" signal in the stack today is depth-driven:

- `MotionTracker.computeVelocity` derives approach rate from `depthHistory`, which is LiDAR.
- `CollisionPredictor.assess` falls back to `bandDepth`, which is LiDAR.

So nothing fires until LiDAR has a return. The iPhone LiDAR horizon is about 5 m and goes sparse on
thin vertical objects, which are exactly the things in the YOLO-World vocabulary (`pole`, `bollard`,
`parking meter`, `street light`). A pole at 6 m is invisible to the belt until the wearer is about
5 m out, roughly 3 seconds at a walking pace. This layer wins those seconds back from the camera.

## The signal: constant bearing plus looming

Two monocular cues predict a collision with no depth at all. Either one alone is a false positive;
both together is the flag.

1. **Constant bearing.** Under egomotion, an object whose box center holds near the wearer's heading
   across frames is on a collision course. This is the maritime "constant bearing, decreasing range"
   rule. Things the wearer will walk past drift toward a frame edge. Things they will hit stay put.
   The center band is the middle third of the frame, the same thirds split the rest of the stack uses.

2. **Looming.** The box growing in height across frames means closing distance. Time-to-contact is
   size over the rate of size growth (`ttc = height / (d height / dt)`), depth-free. Height is the
   expansion cue rather than width or area because it is steadier for tall thin objects and survives
   side-occlusion.

Centering alone is not enough. A building down the street sits centered too. The looming gate is what
separates "far thing dead ahead" from "thing I am about to walk into."

**One confound, handled with a sensor we already have.** When the wearer turns, everything slides
sideways, so a centered reading can be an artifact of their own yaw. `MotionService` runs CoreMotion
at 50 Hz. The tracker gates the bearing streak on yaw rate: a centered frame only counts while the
wearer is walking roughly straight. A turn resets the streak.

## Where it plugs in

`BearingTracker` is a pure type that runs parallel to `MotionTracker`, one per detection frame.

- **Input:** `BoxObservation`, a detector-agnostic per-frame box carrying `horizontalNorm` and
  `boxHeight`. Map `PersonDetection` into it today, map `CVDetection` into it once
  `ObjectDetectionService` lands. The tracker never learns which detector fed it.
- **State:** per-track ring buffers of horizontal position and box height, plus a centered-streak
  counter. The same shape and matching `MotionTracker` uses, so it reads as a sibling.
- **Output:** an `InterferenceFlag` (label, side, centered-frame count, time-to-contact, confidence)
  for any object that currently meets the centered-and-looming bar.

The decision logic (`isCentered`, `loomRatePerSecond`, `evaluate`, `confidence`) is pure and static,
so every threshold is unit-tested with no camera. Thresholds live in `InterferenceParameters`, in the
house style of `MotionParameters`.

## What the flag triggers, and the safety rule

The flag is a soft, additive advisory: a light, distinct belt tap on the center quadrant plus a
spoken heads-up ("something ahead" at low confidence, a named closing object at high). It is the
lowest tier in the cue arbitration.

The rule that makes this safe to add: **the early-warning flag never overrides or delays a real
hazard cue.** When LiDAR or the depth collision tier later confirms the obstacle, its graded cue
takes over and this soft tap steps aside. The layer runs ahead of LiDAR by design, on lower
confidence, so it is allowed to be soft-wrong and is never allowed to gate a hard stop. This is the
same discipline the handoff applies to the Claude path: additive lead time, never on the safety
floor.

It slots into `AppModel.tick` below the person and collision cues, behind a config flag.

## Why build it now, against the current branch

The reliability of the signal is pure math over a sequence of boxes. It does not depend on which
detector produced them. Building it now, validated against the live `PersonDetector` (which already
keeps the full box), gets the math proven on-device against a real walking person days earlier, while
the Part B merge in the handoff is still in flight. That merge is the riskiest in the project (two CV
implementations, a gate reconciliation, a thermal soak of a heavier model). Coupling the early-warning
layer to it would inherit all of that risk and make this layer un-demoable on its own.

Because `BoxObservation` is detector-agnostic, the layer proven against people upgrades to full-vocab
coverage (poles, bollards) the moment `ObjectDetectionService` lands, with no rework in
`BearingTracker`. Build now, designed to generalize.

## Build order

| Step | What lands | Gate |
|---|---|---|
| 1 | `BearingTracker` + `InterferenceParameters` pure type, with the synthetic-sequence tests | tests green: centered+looming fires, either alone stays silent, a head turn builds no streak |
| 2 | Map `PersonDetection` into `BoxObservation`, run the tracker on the live person frames, surface flags in the demo console only | a person walked straight at the camera flags before the LiDAR cue; a person crossing laterally does not |
| 3 | Wire the soft cue into `AppModel.tick` below the collision tier, behind a config flag: light center tap plus the spoken heads-up | the flag fires the soft tap and never delays or masks a LiDAR or person cue |
| 4 | Generalize: feed `CVDetection` into `BoxObservation` once `ObjectDetectionService` is on the branch | poles and bollards flag at range with the same code path |
| 5 | Add the flag to `PerceptionSnapshot` as a per-band field so the Claude advisor speaks with real lead time | the advisor can say "pole ahead, closing" before LiDAR sees it |

Steps 1 and 2 are done. Step 1 is the tracker and its tests. Step 2 runs the tracker live off the
person tier and shows its flags in the demo console, with no belt path touched: `DepthService.applyVision`
maps each frame's overlay boxes into `BoxObservation`, feeds them to a `BearingTracker` on the main
actor with the live yaw rate from `MotionService`, and pushes the flags to an `InterferenceStore` the
camera panel reads. Step 3 onward touches the belt path, so those stay deliberate follow-ups.

## Street-obstacle vocabulary (YOLO-World)

The early-warning layer earns its keep on fixed, thin, vertical things that LiDAR misses at range and
that a pedestrian walks straight into. The person tier proves the math; this is the vocabulary the
layer should watch once `ObjectDetectionService` and the YOLO-World export land (step 4). The export
vocabulary is frozen at export time and the class strings are learned text embeddings, so this list is
a contract: it must match `set_classes()` exactly, and a longer list dilutes per-class accuracy and
costs compute, so it stays curated rather than exhaustive.

The current export vocabulary (on `cole/computer-vision`, `CitrusSquadConfig.visionNavigationClasses`)
has 20 classes and misses trees outright. Proposed additions, grouped by how they relate to this layer:

**Fixed vertical infrastructure (prime early-warning targets).** Thin, stationary, LiDAR-sparse at
range, and dead ahead is exactly where they hurt. These are the classes the bearing flag should
prioritize:

```
pole, utility pole, sign post, street light, bollard, tree trunk,
parking meter, fire hydrant, mailbox, traffic cone, construction barrier,
scaffolding, fence, railing, sandwich board sign, bus stop sign
```

`tree trunk`, not `tree`: a whole-tree box swells with the canopy, which sits overhead and looms
differently from the trunk you actually walk into, so the trunk class keeps the looming estimate
honest. Keep `tree` only if export testing shows the model will not ground `tree trunk`.

**Movers (handled by the motion and collision tier, not this layer).** Already in the vocabulary and
worth keeping, but their early warning is approach velocity from `MotionTracker`, not constant bearing:

```
person, bicycle, car, motorcycle, bus, truck, dog, cat, scooter, stroller
```

**Overhead and ground hazards (camera-only, LiDAR cannot help).** The depth bands sample a strip
biased above center and miss both of these. Stretch additions, only if the export has headroom:

```
tree branch, awning, open car door, curb, step, pothole
```

The forward design note: `BearingTracker` does not filter by class today, it flags anything centered
and looming. Step 4 should add a `CitrusSquadConfig.earlyWarningPriorityClasses` set (the fixed-
infrastructure block above) so the layer leans on the classes where pre-LiDAR lead time matters and
leaves the movers to the motion tier, rather than double-cueing them.

## Tests

All pure, all synthetic, no device:

- The center band is the middle third.
- Loom rate is positive for a growing box, zero for a static one.
- Centered and looming fires; centered-but-static and looming-but-not-centered do not.
- A run of centered frames during a fast yaw builds no streak and fires nothing.
- A full sequence of walking straight at a centered, growing object fires at high confidence.

When real footage exists, add recorded-sequence cases the way the CV layer plans to, and tune the
thresholds in `InterferenceParameters` against them.

## Config additions

All in `InterferenceParameters` (new), not scattered into `CitrusSquadConfig`, matching how
`MotionParameters` holds the motion thresholds:

- `centerHalfWidthNorm`, `heldFrames` — the constant-bearing test.
- `yawGateRadPerSecond` — the self-rotation gate.
- `minLoomRatePerSecond`, `ttcWarnSeconds`, `minBoxHeight` — the looming test.
- `historyLength`, `matchRadiusNorm`, `expiryFrames`, `detectionHz` — track management and rate.

The eventual soft-cue intensity reuses `CitrusSquadConfig.intensityFloor` so it is felt but reads as
gentler than a graded hazard tap. Do not add a parallel intensity constant.

## Open questions and risks

1. **Box height stability.** Looming leans on a clean height estimate. A detector that jitters the box
   top or bottom frame to frame will noise the loom rate. The `minBoxHeight` floor and the multi-frame
   window damp it; confirm against real footage before trusting the ttc number.
2. **Yaw gate threshold.** Too low and normal walking sway resets the streak; too high and a real turn
   leaks a false centered reading. `yawGateRadPerSecond` needs one tuning pass on device with the belt
   worn, not bench-held.
3. **Center-band width versus heading offset.** The camera's optical axis is not exactly the wearer's
   walking heading once the phone is belt-mounted at an angle. If the mount tilts the frame, the center
   band may need an offset, not a symmetric 0.5. Calibrate once at mount time.
4. **False positives on crowds.** Several people ahead, all roughly centered, could each flag. The soft
   tier and the single-cue arbitration keep this from spamming the belt, but the spoken line should
   summarize ("people ahead"), not enumerate. Handle in the audio phrasing, not here.
5. **It must stay additive.** The whole safety argument rests on the flag never delaying a LiDAR cue.
   Any wiring in step 3 that lets the soft tap pre-empt a real hazard cue is a regression, not a tweak.

## File map

| File | Change |
|---|---|
| `ios/Sources/Perception/BearingTracker.swift` | Done (step 1). The pure tracker, `BoxObservation`, `InterferenceFlag`, `InterferenceParameters`. |
| `ios/Tests/BearingTrackerTests.swift` | Done (step 1). Synthetic-sequence tests for the decision logic. |
| `ios/Sources/Perception/InterferenceStore.swift` | Done (step 2). New. Main-actor `@Observable` surface the demo console reads. |
| `ios/Sources/Sensors/DepthService.swift` | Done (step 2). Runs the tracker in `applyVision` off the overlay boxes; holds `latestYawRate`. |
| `ios/Sources/Sensors/MotionService.swift` | Done (step 2). Exposes `yawRateRadPerSecond` for the self-rotation gate. |
| `ios/Sources/AppModel.swift` | Done (step 2). Owns `interference`, wires it in, feeds yaw each tick. Step 3 adds the soft cue here. |
| `ios/Sources/UI/Demo/CameraPanel.swift` | Done (step 2). `EarlyWarningBanner` over the preview; flagged-frame count. |
| `ios/Sources/CitrusSquadConfig.swift` | Edit (step 3). The early-warning enable flag; reuse `intensityFloor` for the soft tap. |
| `ios/Sources/Perception/ObjectDetectionService.swift` | Edit (step 4). Map `CVDetection` into `BoxObservation`; the vocabulary above. |
| `ios/Sources/Perception/PerceptionSnapshot.swift` | Edit (step 5). Carry the flag per band for the Claude advisor. |
| `PersonDetector.swift` is left unchanged: the tracker reads the overlay `DepthService` already produces, so the person tier needs no edit. |

When work lands, update [`../STATUS.md`](../STATUS.md): move items between in-flight and done, bump the
latest commit, add a session-log line.
