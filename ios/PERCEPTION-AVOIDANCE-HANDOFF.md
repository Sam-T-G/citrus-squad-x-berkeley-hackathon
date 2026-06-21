# Perception + AI Avoidance Handoff

The full chain from open-vocabulary object detection to AI-reasoned avoidance, on-device, feeding the
belt and the audio tier. This is the committed plan: YOLO-World is in, not a maybe. This doc is the
end-to-end spec that ties the detection layer, the motion and collision layers, the structured
perception snapshot, and the Claude reasoning step into one pipeline.

**Owner:** Sam (iOS lane, all Swift). Cole owns the CoreML export and the webcam validation. Josh
owns the audio sink that speaks the result.

## Read order

1. This file. It is the architecture and the build order.
2. [`YOLO-WORLD-PLAN.md`](YOLO-WORLD-PLAN.md) for the model export specifics and the thermal gates.
   This doc commits to the swap; that doc holds the export recipe and the go/no-go bars.
3. [`CV-PORT-PLAN.md`](CV-PORT-PLAN.md) for the existing hazard seam (`VisionHazardSource`, `Hazard`,
   `AppModel` arbitration) the detection layer plugs into. Built and proven for the person tier.
4. [`../docs/12-perception-and-safety-design.md`](../docs/12-perception-and-safety-design.md) §4 and
   §6 for the safety-over-direction arbitration and the settle/hysteresis/refractory discipline.
5. [`../docs/14-voice-and-reasoning-plan.md`](../docs/14-voice-and-reasoning-plan.md) for the Claude
   reasoning tier and the perception-snapshot shape it was waiting on. This doc builds that snapshot.

## Where this sits in the project trajectory

The safety story has been climbing one tier at a time, each shipping on its own:

```
LiDAR proximity  (built)  ->  raw distance, fires the belt regardless of what the thing is
person tier      (built)  ->  YOLOv8n names a person, fuses depth, gated 0x10 cue
open-vocab detect (this)  ->  YOLO-World names poles, bollards, cans, the things people walk into
motion + collision (this) ->  per-object approach velocity, threat level, dodge geometry
AI avoidance     (this)   ->  Claude reasons over the whole structured scene, speaks the avoidance
```

The belt and the audio sink already exist as output endpoints (`CueSink`, `AudioCueSink`). The hazard
input seam already exists (`HazardSource`, `VisionHazardSource`). This work fills the middle: a richer
detector, the geometry that turns detections into an avoidance, and the structured context object that
lets the AI reason about it.

## The end-to-end pipeline

```
ARFrame (RGB + LiDAR depth, one synchronized pair, ~10 Hz from DepthService)
   |
   v  throttle to ~3-5 Hz
YOLO-World detect  ->  [CVDetection]  (open-vocab label, confidence, horizontalNorm)
   |
   v
MotionTracker      ->  [TrackedObject]  (+ motionState, approach m/s, lateral norm/s)
   |
   +-------------------------------+----------------------------------+
   |                               |                                  |
   v                               v                                  v
CollisionPredictor          PerceptionSnapshot                 fuseTracked -> Hazard
(threat + dodge geometry)   (the AI context object)            (belt cue, on-device, instant)
   |                               |                                  |
   |                               v                                  v
   |                        Claude avoidance reasoning          VisionHazardSource.report()
   |                        (verified, fire-and-forget)               |
   |                               |                                  v
   +----> ObstacleThreat ----------+----> AudioCueSink            AppModel arbitration -> belt
                                          ("pole ahead, step left 1 pace")
```

The split that matters: **the belt path is on-device and instant** (LiDAR distance plus collision
geometry, never waiting on the network). **The AI path is cloud, slower, and additive** (it speaks
context and a reasoned avoidance, and it is allowed to be late or to fail). This is the one hard rule
from `docs/14` §"The one hard rule," carried through here: nothing in the AI path gates the belt.

## Decisions locked for this work

- **Adopt `ObjectDetectionService` as the detector, retire `PersonDetector`'s live role.** The demo
  branch (`sam/ios-app-base`) currently runs `PersonDetector` (person only). Cole's branch
  (`cole/computer-vision`) has `ObjectDetectionService` plus `MotionTracker`, `MotionParameters`, and
  `CollisionPredictor`, which are exactly the layers the AI avoidance step needs. Bring those onto the
  demo branch and make `ObjectDetectionService` the one detector hooked to `DepthService.onFrame`.
  Keep `PersonDetector`'s time-based gate logic as a reference for reconciling the gate (see Part B);
  do not run both detectors against the same ARSession.
- **One ARSession, one frame, both signals.** `DepthService` already forwards each frame's
  `capturedImage` (RGB) and `sceneDepth.depthMap` (LiDAR) through `onFrame`. We do not stand up a
  second `AVCaptureSession`. This halves the thermal cost and removes RGB-to-depth skew.
- **YOLO-World is committed; v8n stays bundled as the fallback model file.** Both `.mlpackage`s ship.
  A config flag picks which loads. If the world model runs too hot on the day, flip back to v8n
  without a rebuild.
- **The belt never waits on Claude.** Belt cues come from `fuseTracked -> Hazard` and the LiDAR
  reflex. Claude only writes audio lines and only after the belt has already fired.

## Part A — YOLO-World detection

### Export (Cole)
Per [`YOLO-WORLD-PLAN.md`](YOLO-WORLD-PLAN.md) Step 1 and `../HANDOFF.md` "YOLO-World implementation
pipeline." `YOLOWorld('yolov8s-worldv2.pt')`, `set_classes([...])` with the navigation vocabulary,
`export(format='coreml', nms=True)`. The `nms=True` is required or Vision gets raw tensors and detects
nothing. Validate against `cv/webcam_test.py` before handing over. The vocabulary is frozen at export
time, so the class list below is the contract; changing it means a re-export.

Vocabulary (start here, tune against demo-site footage):
```
person, bicycle, car, motorcycle, bus, truck, dog, cat,
pole, bollard, trash can, garbage bin, parking meter, street light,
fire hydrant, traffic cone, construction barrier, bench, stop sign, traffic light
```

### Bundle both models (Sam)
Drop `yolov8s-worldv2.mlpackage` into `ios/Sources/Resources/` next to the existing
`yolov8n.mlpackage`. Reference it in `Project.yml`, run `xcodegen generate`.

### Swift (Sam)
`ObjectDetectionService` already loads `yolov8n` by a hardcoded resource name and filters on a
hardcoded `navigationClasses` set. Two changes:

- Load `CitrusSquadConfig.visionModelName` (default `"yolov8s-worldv2"`, fallback `"yolov8n"`) instead
  of the hardcoded `"yolov8n"` in `loadModel()`.
- Move `navigationClasses` into `CitrusSquadConfig.visionNavigationClasses` so the Swift filter and
  the export vocabulary live next to each other and can be checked for drift. The class-name strings
  must match the export exactly; YOLO-World keys on learned text embeddings, so `"trash can"` and
  `"trashcan"` are different classes.

`runDetection`, the `VNRecognizedObjectObservation` path, the orientation handling, and the fusion
math all stay identical. The model is a wider closed-vocab detector after export; the Swift sees the
same observation type.

### Thermal
The smallest YOLO-World is roughly 4x v8n's parameters. Drop the throttle: `ObjectDetectionService`
runs `callTick % 2` (1-in-2 of DepthService's ~10 Hz, so ~5 Hz). Start the world model at `% 3`
(~3 Hz) and measure. The decide loop stays at 10 Hz; detection does not need to keep up. The existing
thermal gate in `AppModel` (`depth.visionEnabled` flips off at `.serious`) already drops the camera
tier under heat and leans on LiDAR, so the belt never goes dark. Confirm it still trips with the
heavier model in the loop. Run the soak in `docs/12` §6 before trusting the tier.

## Part B — motion and collision (adopt Cole's layers)

Bring these four files from `cole/computer-vision` onto the demo branch unchanged in spirit, fixing
only what the merge needs:

- `Perception/ObjectDetectionService.swift` — the detector, hooked to `DepthService.onFrame`. Runs
  YOLO-World, tracks motion, fuses to a `Hazard` for the belt, exposes `currentThreat` and
  `movingObjects` for the AI tier.
- `Perception/MotionTracker.swift` — cross-frame tracking. Matches detections by label plus
  horizontal proximity, keeps per-object depth and horizontal ring buffers, computes approach
  velocity and lateral rate, classifies `stationary / moving / approaching / receding` behind a
  settle filter. No AI, fully testable on synthetic frame sequences.
- `Perception/MotionParameters.swift` — every motion threshold in one place. Tune, rebuild, test.
- `Perception/CollisionPredictor.swift` — pure threat-and-dodge logic. Grades distance into
  `advisory / warning / urgent`, boosts approaching objects one tier, picks a dodge side by checking
  which LiDAR band is open, returns an `ObstacleThreat` with a `NavigationAction`.

### Reconcile the gate
`ObjectDetectionService.advance` uses a frame-count settle and refractory; `PersonDetector.decide`
uses a time-based settle, a hysteresis band, and a refractory floor in seconds. The time-based gate is
the better-tested one and handles a body hovering at the threshold without chatter. Port
`PersonDetector.decide`'s hysteresis and time-based refractory into `ObjectDetectionService`'s settle
path, or factor the gate into a shared `HazardDebouncer` both can call. Do not ship two divergent gate
implementations.

### Config additions
`ObjectDetectionService` and `CollisionPredictor` reference `CitrusSquadConfig.cv*` constants that live
on Cole's branch (`cvConfidenceThreshold`, `cvSettleFrames`, `cvRefractoryFrames`, `cvUrgentMeters`,
`cvWarningMeters`, `cvAdvisoryMeters`). Bring those across with the files. Reuse the existing
`proximityThresholdMeters` (1.8) and `dangerNearMeters` (0.5) for the belt-side gate; do not add
parallel distance constants.

### Tests
Port `cv/tests/test_pipeline.py`'s fusion assertions (already done for `PersonFusion`) and add
synthetic-sequence tests for `MotionTracker` (approaching vs stationary vs lateral) and
`CollisionPredictor` (threat tiers, dodge-side selection, approaching-boost). These are pure and need
no device.

### Wire into AppModel
`ObjectDetectionService.start(depthService:hazard:)` registers the `onFrame` callback and loads the
model async. `AppModel` holds the reference and starts it alongside `DepthService`. The belt path is
done at this point: `fuseTracked -> Hazard -> VisionHazardSource.report()` flows through the existing
arbitration with zero core-loop changes.

## Part C — the PerceptionSnapshot (the AI context object)

This is the connective tissue the AI tier needs and the piece `docs/14` flagged as its top blocker
(blindspot #3: "The perception snapshot does not exist yet"). It is a single structured value that
captures the whole scene at one instant, so Claude reasons over real data instead of a raw frame.

### The type
A new `Perception/PerceptionSnapshot.swift`. Pure value type, `Sendable`, assembled on the main actor
from state that already exists. The shape mirrors the proposal in `docs/14` §"The perception
snapshot," now fillable because YOLO-World supplies the per-band class lists v8n could not.

```swift
struct PerceptionSnapshot: Sendable {
    struct Band: Sendable {
        var nearestMeters: Double           // from DepthService.bands
        var objects: [TrackedObjectSummary] // YOLO-World labels + motion in this band
    }
    struct TrackedObjectSummary: Sendable {
        var label: String
        var distanceMeters: Double
        var motionState: MotionState        // stationary / moving / approaching / receding
        var approachRateMetersPerSecond: Double
    }
    var timestamp: Double
    var left: Band
    var center: Band
    var right: Band
    var route: RouteContext?                 // next turn, distance, on-route, from RouteEngine
    var confidence: Confidence               // low / medium / high
    enum Confidence: String, Sendable { case low, medium, high }
}
```

### Assembly
A `PerceptionSnapshotBuilder` (or a method on `AppModel`) reads three sources that already exist and
bins each tracked object into a band by `horizontalNorm` (the same thirds split `CollisionPredictor`
and `quadrantMask` use):

- `DepthService.bands` for `nearestMeters` per band (LiDAR, ground truth for distance).
- `ObjectDetectionService.movingObjects` plus the stationary tracked objects for the per-band labels
  and motion. `movingObjects` is already exposed on the main actor.
- `RouteEngine` for the route context, read through the existing snapshot boundary so a slow read
  never stalls the heartbeat.

`confidence` is `low` when LiDAR returns are sparse or the tracker has little history, `high` when
distance and labels agree across several frames. The evaluator leans on this: never claim a band is
clear unless `nearestMeters` supports it, never name an object the band's `objects` list does not
contain, and when confidence is low, say so rather than guess.

### XML serialization for Claude
Per Anthropic prompt guidance, serialize the snapshot to XML-tagged input, not prose, so the model
reads structure. One `func xmlForClaude() -> String` on the snapshot. Bands, objects, route, and
confidence each get a tag. This is the literal context string passed to the reasoning step.

## Part D — AI avoidance reasoning

Two consumers read the same snapshot. Both run off the safety path and never block the belt.

### D1 — Reactive avoidance advisor (the new "context passing to AI for avoidance")
When `ObjectDetectionService.currentThreat` crosses into `warning` or `urgent`, or a tracked object
turns `approaching`, build a `PerceptionSnapshot`, send it to Claude, and get back one verified
avoidance line for the audio sink. Fire-and-forget: the belt already tapped from the on-device
geometry; this adds the spoken "what and what to do."

```
threat warning/urgent OR new approaching object
  -> build PerceptionSnapshot
  -> SceneCache lookup (band + approx distance + label)   cache hit -> speak instantly
  -> on miss: Claude draft (fast model) over snapshot XML  "pole ahead, step left one pace"
  -> Claude verify (stricter model) against the snapshot   reject anything unsupported by the data
  -> AudioCueSink speaks the verified line; write to SceneCache
```

Latency budget: ~300-500 ms draft on the fast model, a short verify, a few hundred ms TTS, so under a
second for a fresh line, near-zero on a cache hit. That is fine for spoken context and unacceptable for
belt timing, which is exactly why the belt never waits on it. `SceneCache` (keyed loosely by band plus
approximate distance plus label, per `../HANDOFF.md`) makes a scouted demo route speak instantly with
no live network dependency. Scout the route beforehand to pre-populate it.

What YOLO-World changes about this step: Claude shifts from *identifying* the object (its old job in
`../HANDOFF.md` when v8n could not name street infrastructure) to *reasoning about avoidance* given an
already-labeled, already-tracked scene. The label comes from the model; Claude decides the move and
phrases it safely. That is a stronger, more verifiable use of the model than asking it to name a crop.

### D2 — Conversational describe_surroundings()
The pull-based path from `docs/14`. The wearer presses and asks "what is around me"; the function reads
the same `PerceptionSnapshot`, drafts a one-sentence summary with the fast model, verifies it against
the snapshot with the stricter model, and hands the Voice Agent a line that is already safe to speak.
Pull, never push: it narrates only when asked, never on a timer.

### The reasoning contract
Both paths share a system prompt that states the rules: you are given a structured scene snapshot, not
an image; recommend at most one avoidance action; prefer the dodge side the snapshot marks open; never
contradict the LiDAR distances; if confidence is low, say the path is uncertain rather than inventing
detail. The verify pass re-checks the draft against the snapshot and rejects any claim the data does
not support. Keep the drafter and evaluator as direct Anthropic API calls inside the Swift function
(per `docs/14` §"Where the evaluator lives"), so the safety check stays on our side and a key is not
handed to a third party.

## Concurrency, thermal, and safety rules (SWIFT.md)

- `ObjectDetectionService` runs inference and tracking on ARKit's serial callback queue
  (`nonisolated`), and only the `Sendable` results (`Hazard?`, `currentThreat`, `movingObjects`) hop
  to the main actor. The `VNCoreMLModel`, `MotionTracker`, and frame counters stay on that one queue
  via `nonisolated(unsafe)`, the same pattern `DepthService.frameTick` uses.
- The Claude calls live in their own `Task` / actor, never on the 10 Hz decide loop or the 100 ms
  heartbeat. A slow or failed call cannot stall the belt, by construction.
- No force unwrap, no `try!`, no completion handlers, no `DispatchQueue` for app logic. A bad frame or
  a failed request yields `nil` and the belt falls back a tier, never a crash. `os.Logger`, not
  `print`. One primary type per file, grouped under `Perception/`.
- Thermal is the demo-killer. The throttle, the one-ARSession decision, and the `.serious` degrade
  ladder all exist to protect it. The belt path survives every degradation; the AI path is allowed to
  drop out entirely.

## Milestones and gates

Each ships on its own and de-risks the next. Cut lines noted.

| Milestone | What lands | Gate |
|---|---|---|
| **A — model swap** | YOLO-World exported, both models bundled, config flag, Swift filter on the world vocab | diagnostics console shows `pole` / `trash can` boxes on device; flag off = today's behavior |
| **B — tracking + collision** | `ObjectDetectionService` + `MotionTracker` + `CollisionPredictor` on the demo branch, gate reconciled, tests green | an approaching object fires a graded belt cue on the correct side; synthetic-sequence tests pass |
| **C — snapshot** | `PerceptionSnapshot` + builder + XML serialization | the snapshot reads true against a known scene (bands, labels, motion, route all correct) |
| **D1 — reactive advisor** | threat -> snapshot -> Claude draft+verify -> audio, with `SceneCache` | on a warning-range pole, the audio speaks a verified "step left" within a second, belt already tapped |
| **D2 — describe_surroundings** | the pull path reads the same snapshot | "what is around me" speaks one sentence that never claims more than the snapshot supports |

Cut order if time runs short: keep through B (the belt story is whole with open-vocab detection and
collision geometry, no AI needed). D1 and D2 are the pitch's wow, not the safety floor. If the export
will not convert or the world model runs hot at 3 Hz, fall back to the bundled v8n and ship B on COCO
classes plus Claude for the street-infrastructure labels.

## File map

| File | Change |
|---|---|
| `ios/Sources/Resources/yolov8s-worldv2.mlpackage` | New. Cole's export, bundled beside v8n. |
| `ios/Sources/CitrusSquadConfig.swift` | Add `visionModelName`, `visionNavigationClasses`, the `cv*` threat constants; lower the world-model throttle. |
| `ios/Sources/Perception/ObjectDetectionService.swift` | Bring from Cole's branch. Load the configured model; vocab from config; reconcile the gate. |
| `ios/Sources/Perception/MotionTracker.swift` | Bring from Cole's branch. Unchanged. |
| `ios/Sources/Perception/MotionParameters.swift` | Bring from Cole's branch. Unchanged. |
| `ios/Sources/Perception/CollisionPredictor.swift` | Bring from Cole's branch. Unchanged. |
| `ios/Sources/Perception/PerceptionSnapshot.swift` | New. The AI context object + XML serialization. |
| `ios/Sources/Perception/SceneCache.swift` | New. Loosely-keyed label/avoidance cache for zero-latency demo. |
| `ios/Sources/Perception/AvoidanceAdvisor.swift` | New. Threat -> snapshot -> Claude draft+verify -> audio. Off the safety path. |
| `ios/Sources/Voice/VoiceCommand.swift` | Edit. `describe_surroundings()` reads `PerceptionSnapshot`. |
| `ios/Sources/AppModel.swift` | Edit. Start `ObjectDetectionService`; own the snapshot builder and the advisor. No arbitration change. |
| `ios/Sources/Perception/PersonDetector.swift` | Retire its live role (keep the gate logic as the reconciliation reference). |
| `ios/Project.yml` | Bundle the second model; regenerate. |
| `ios/Tests/` | Add `MotionTrackerTests`, `CollisionPredictorTests`, `PerceptionSnapshotTests`. |

## Open questions and risks

1. **CoreML export of YOLO-World may fight back.** RepVL-PAN converts less cleanly than vanilla v8.
   Cole test-exports on the Mac and validates against `cv/webcam_test.py` before any Swift work. This
   is the make-or-break and it is gated in `YOLO-WORLD-PLAN.md`.
2. **Thermal headroom for a 4x-heavier model is unproven.** The soak has not run even on v8n. Run it.
   If the world model cannot hold out of `.serious` at 3 Hz, it stays a fallback-to-v8n situation.
3. **Frozen vocabulary.** The class list is fixed at export time. Lock it against the demo
   environment before exporting; a missing class means a re-export, not a runtime tweak.
4. **Two CV implementations are merging.** `PersonDetector` (demo branch) and `ObjectDetectionService`
   (Cole's) overlap. The gate reconciliation in Part B is the real merge work; do it deliberately, do
   not run both detectors against one ARSession.
5. **Snapshot confidence is a safety surface.** If the builder over-reports confidence, the evaluator
   trusts bad data and Claude speaks a wrong avoidance. Bias `confidence` low when LiDAR is sparse or
   tracks are young.
6. **Demo network dependency for the AI path.** Neutralized by `SceneCache` plus scouting the route,
   the same strategy `../HANDOFF.md` lands on. Pre-warm the Claude connection before going on stage.

When work lands, update [`../STATUS.md`](../STATUS.md): move items between in-flight and done, bump the
latest commit, add a session-log line.
