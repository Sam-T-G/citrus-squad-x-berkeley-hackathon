# CV Port Plan — Cole's Python CV into the Swift production app

How we take Cole's tested Python computer-vision layer (`cv/`, now on `main`) and run it on-device in the Citrus Squad iOS app as the person-in-path safety tier (`0x10 vision-danger`). Read [`../STATUS.md`](../STATUS.md) and [`../docs/12-perception-and-safety-design.md`](../docs/12-perception-and-safety-design.md) first; this plan implements the camera tier those two describe.

**Owner:** Sam (iOS lane). Cole owns the Python reference and the CoreML export; he does not write or review Swift. Josh owns the audio sink. This plan stays inside `ios/`.

## Implementation status (2026-06-20)

Landed on `sam/ios-app-base` (commit `561de04`):

- `Perception/PersonFusion.swift` — the depth-fusion math, ported from `cv/pipeline.py`. Pure.
- `Perception/PersonDetector.swift` — YOLOv8n via Vision/CoreML, depth fusion, and the settle /
  hysteresis / refractory gate. The gate transitions are pure.
- `CitrusSquadConfig` vision constants; `DepthService` runs the detector on its ARSession frames.
- `Tests/PersonFusionTests.swift` + `Tests/PersonDetectorTests.swift`, mirroring Cole's
  `tests/test_pipeline.py` and the §6 timing rules.

Verified off-device: the pure fusion math (14 assertions) and the gate state machine (13
assertions) pass, and the whole app compiles clean against the iOS SDK under Swift 6 complete
concurrency.

Held back by one line: `AppModel.attachVision(sink: vision, store: detections)` in `init` plus the
thermal gate in `tick`. Both sit in the working tree but are not committed yet, because `AppModel`
is being co-edited by the Maps integration and I did not want to commit half of that work. They
activate the tier; until they land it is wired but dormant.

**P0 model — done.** `ios/Sources/Resources/yolov8n.mlpackage` (commit `89103b9`), exported from
ultralytics 8.4 with `nms=True`. Validated: it is an NMS pipeline (mlProgram detector +
`nonMaximumSuppression`), class 0 is `person` across the 80 COCO labels, and Xcode compiles it to
`yolov8n.mlmodelc` in the app bundle, which is what `PersonDetector` loads. So Vision returns
`VNRecognizedObjectObservation` and the `identifier == "person"` filter is correct.

Remaining, all needing the phone:

- **Orientation calibration:** confirm `PersonDetector.toNativeNormalized`'s `.right` case with a
  left/right target. This is the one runtime unknown; everything numeric is tested.
- **On-device build + run:** no iOS simulator is installed here, so the device build and the live
  cue are the last checks.

A note on the existing scaffold: `Sensors/CameraService.swift` (a separate `AVCaptureSession`) and
`Perception/DetectionStore.swift` predate this and back the demo overlay. The camera and ARKit depth
are mutually exclusive on one device, so the live fused cue runs through the ARSession in
`DepthService`, not `CameraService`. `DetectionStore` still receives the boxes for the overlay.

## The short version

Cole already proved the algorithm in Python: YOLOv8n finds a person, ARKit-style LiDAR depth gives the distance, and the two fuse into one detection with a side and a range. We do not re-derive any of that. We translate the same math to Swift, run YOLOv8n through CoreML and Vision on the phone, and feed the result into the hazard seam the app already has. The win condition is a person stepping into frame producing a `0x10` tap on the correct side, graded by distance, preempting the turn cue, and settling cleanly when they leave.

## What is already done for us (the seam)

The base app was built with this exact feature in mind. These exist today and we build against them, not around them.

- **`Perception/VisionHazardSource.swift`** — the plug point. One call wires the whole feature in:
  ```swift
  appModel.vision.report(kind: .person, side: quadrant, distanceMeters: fusedDistance)
  appModel.vision.clear()   // when the path is clear
  ```
- **`Perception/Cues.swift`** — `Hazard.Kind.person` already exists, and `ResolvedCue.intensity(forDistance:)` already grades 0.5 m to 1.8 m into a 255-to-96 tap. We reuse it as is.
- **`Networking/LC2Packet.swift`** — `LC2Event.visionDanger = 0x10` is defined. `QuadrantMask` has `.front/.left/.right/.back`. No protocol change needed.
- **`AppModel.swift`** — `currentHazard()` already collects `vision.currentHazard` and ranks a person ahead of an obstacle, and `tick()` already preempts the turn cue with any hazard at 10 Hz. The moment `report(...)` fires, arbitration and the belt path work with zero further wiring.
- **`Sensors/DepthService.swift`** — already owns a running `ARSession` with `.sceneDepth` and reads `DepthFloat32` at ~10 Hz. This is the frame pump we extend. We do not stand up a second camera.

So the feature is one new detector that turns ARFrames into `report(...)` calls. Everything downstream is built.

## The one architectural decision that matters

**One ARSession, one frame, both signals.** Cole's Python fuses an RGB frame and a depth map that arrive over the wire as a synchronized pair. On iOS we get that pair for free: every `ARFrame` carries both `capturedImage` (RGB) and `sceneDepth.depthMap` (LiDAR), captured at the same instant. `DepthService` already receives every frame.

We therefore do not add a `CameraService`. We extend the single ARFrame source in `DepthService` to forward each (throttled) frame to the new detector, which reads the RGB for YOLO and the depth for fusion off the same frame. This halves the camera/thermal cost versus a second AVCapture session and removes the RGB-to-depth time skew that Cole's wire format has to assume away. Thermal headroom is the single biggest demo risk per STATUS, so this is the decision that protects the demo.

## Target shape (Swift mirror of Cole's contract)

Mirror `cv/detection.py`'s `DepthFusedDetection` so the math is auditable against the Python tests. Pure value type, no I/O.

```swift
struct PersonDetection: Sendable, Equatable {
    var confidence: Float
    var bboxNormalized: CGRect      // Vision coords, origin bottom-left, [0,1]
    var depthMedianMeters: Double?  // median valid depth in the inner crop
    var depthMinMeters: Double?     // closest valid point in the inner crop (drives intensity)
    var horizontalNorm: Double      // 0 = far left, 1 = far right (bbox center x)
}
```

**Update (commit `3c83f75`): the narrowing to person-only is undone.** The on-device filter now reads `CitrusSquadConfig.visionNavigationClasses`, the 21-class set held in lockstep with `NAVIGATION_CLASSES` in `cv/detection.py`, and `PersonDetection` carries the real COCO label (`person`, `bicycle`, `bench`, `parking meter`, ...) through the overlay instead of the hardcoded `"person"`. The gate, depth fusion, and intensity math are untouched (they key on distance and side, not class), so the `0x10` cue behaves exactly as before; the win is real labels for the overlay, diagnostics, and the spoken tier. The base demo beat is still person-in-path; the wider set is the richer-haptics layer riding on the same code path. `PersonDetector.navigationLabel` is the one place the filter lives.

## Pipeline phases

Each phase has an acceptance bar. Do not advance until it is green. This mirrors the P0–P5 ladder in `docs/12` §10.

### P0 — Bring the branch current and export the model
- Merge `main` into `sam/ios-app-base` so Cole's `cv/` reference and the CoreML export land in the working tree.
- Export YOLOv8n to CoreML **with NMS baked in** so Vision returns clean object observations:
  ```sh
  python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True)"
  ```
  This is Cole's deliverable. The `nms=True` matters: without it Vision hands back raw tensors and we owe our own non-max suppression. With it, Vision returns `VNRecognizedObjectObservation` with label, confidence, and a normalized box.
- Drop `yolov8n.mlpackage` into `ios/Sources/Resources/` and reference it in `Project.yml`. Confirm it is gitignored only if large; otherwise commit it so any teammate can build.
- **Acceptance:** project generates and builds with the model bundled; `import Vision` and the model load with no runtime error on the phone.

### P1 — Detector module, RGB only
- Add `Perception/PersonDetector.swift`: an actor that holds the `VNCoreMLModel` and runs `VNCoreMLRequest` against a `CVPixelBuffer`, filtered to the `person` class above `CitrusSquadConfig.visionConfidenceThreshold` (0.35, Cole's default).
- Feed it from `DepthService`'s frame callback at a throttled rate (see P4). Run the request off the main actor; only the final `PersonDetection?` hops back.
- Handle orientation: the rear camera in portrait needs `CGImagePropertyOrientation.right` passed to `VNImageRequestHandler`. Get this wrong and every box is rotated.
- **Acceptance:** logs a person box with confidence when someone is in frame, nothing when the frame is empty. No depth yet.

### P2 — Depth fusion (the Python math, line for line)
Replicate `cv/pipeline.py:98–122` exactly so Cole's 12 pipeline tests port across unchanged in spirit:
- Scale the Vision box into the 256×192 depth buffer. Vision boxes are normalized with a bottom-left origin; flip Y and multiply by depth width/height. Do not assume the RGB and depth aspect ratios match without checking. `capturedImage` is 4:3 and `sceneDepth` is 4:3 (256×192), so a straight scale holds, but assert it once on the device and record the real `ARFrame` dimensions (an open item in Cole's HANDOFF).
- Inner 50% crop: `padX = (x2 - x1) * 0.25`, `padY = (y2 - y1) * 0.25`, shrink the box on every side. This is `depthCropRatio = 0.5` and it is what keeps LiDAR edge bleed off the reading.
- Valid set: drop `NaN`, drop non-finite, **drop zero** (the LiDAR no-return sentinel). `depthMedian` from the survivors, `depthMin` from the survivors, both `nil` if the crop is empty.
- `horizontalNorm = bboxCenterX` in [0,1].
- **Acceptance:** a Swift unit-test file `PersonFusionTests.swift` reproduces all 12 assertions from `tests/test_pipeline.py` (correct crop window, min-is-closest, all-NaN-is-nil, zero-is-missing, center/left/right horizontal-norm edges, empty-frame-empty). Green is the contract.

### P3 — Map to a hazard and fire `report(...)`
- Quadrant: split `horizontalNorm` into thirds and map to `.left / .front / .right`, matching `DepthService`'s left/center/right band convention so the side a person fires on is consistent with the side an obstacle fires on. Per the locked side convention in `docs/12` §1, the tap means "the hazard is on this side."
- Distance for intensity: use `depthMinMeters` (closest point), the same field Cole's `server.py` sorts on. Pass it straight to `report(kind: .person, side:, distanceMeters:)`; `ResolvedCue.intensity(forDistance:)` does the 255-to-96 grading we already trust.
- Fire only when `depthMinMeters` is inside `CitrusSquadConfig.proximityThresholdMeters` (1.8 m). A person three rooms away is not a path hazard. Outside the threshold, `clear()`.
- **Acceptance:** person inside 1.8 m produces a `0x10` packet on the correct side with distance-graded intensity, visible in the diagnostics console; person leaves and it returns to idle within one refractory window. Arbitration already proven in `AppModel`, so a person plus an obstacle yields the person cue.

### P4 — Temporal discipline and thermal governance
The two things that separate a demo that wins from one that chatters.

- **Settle / hysteresis / refractory** per `docs/12` §6: require the person to persist `visionSettleFrames` (3) before firing, apply `visionHysteresisMeters` (±0.3 m) so a body at the threshold does not flicker the cue, and hold a `visionRefractorySeconds` (1.0 s) floor between state changes. Put this state in `PersonDetector` or a small `HazardDebouncer`, not in the view.
- **Throttle:** run YOLO at `visionMaxHz` (start at 4 Hz). The decide loop stays at 10 Hz; detection does not need to. Drop every frame that arrives while a request is in flight rather than queueing.
- **Thermal degrade ladder** per `docs/12` §6: wire the detector to `Diagnostics/ThermalMonitor`. At `.serious`, stop running the camera request and lean on LiDAR proximity alone. At `.critical`, the existing depth-drop already applies. The belt never goes dark; it falls back a tier.
- **Acceptance:** a 10-minute continuous run holds out of `.serious` thermal state, and the cue does not chatter when a person stands still at ~1.8 m.

### P5 — Cut gate and demo polish
- **Cut gate** per `docs/05` and `docs/12` §7: if person detection is not firing cleanly by the Saturday integration check (target H+12), disable it with a config flag and demo on LiDAR proximity plus direction. The flag already half-exists as `VisionHazardSource.isEnabled`; surface it in the control panel.
- Confirm the diagnostics console shows the person tier (confidence, distance, side, thermal state) so the pitch can narrate it.
- Tune `visionConfidenceThreshold` and `depthCropRatio` on real demo-room footage, the last two open items in Cole's HANDOFF. Err low on confidence; a missed person is worse than a false tap for a safety device.

## New and touched files (all in Sam's lane)

| File | Change |
| --- | --- |
| `ios/Sources/Perception/PersonDetector.swift` | New. Actor: CoreML request, person filter, fusion, temporal discipline, calls `vision.report`/`clear`. |
| `ios/Sources/Perception/PersonFusion.swift` | New. Pure functions: box scaling, inner crop, median/min, quadrant mapping. The unit-testable core. |
| `ios/Sources/Sensors/DepthService.swift` | Edit. Forward each throttled `ARFrame` (capturedImage + depthMap) to an injected detector. Keep depth-band logic intact. |
| `ios/Sources/CitrusSquadConfig.swift` | Edit. Add the vision constants below. |
| `ios/Sources/AppModel.swift` | Edit. Construct `PersonDetector`, inject into `DepthService`, hold the reference. No arbitration change. |
| `ios/Project.yml` | Edit. Bundle `yolov8n.mlpackage`; link `Vision` and `CoreML`. |
| `ios/Tests/PersonFusionTests.swift` | New. Port Cole's 12 pipeline assertions. |
| `ios/Sources/Resources/yolov8n.mlpackage` | New. Cole's CoreML export. |

## Config additions (`CitrusSquadConfig`)

```swift
// Vision person-in-path tier (mirrors cv/ defaults)
static let visionConfidenceThreshold: Float = 0.35   // Cole's conf default; err low for safety
static let depthCropRatio = 0.5                       // inner-crop to dodge LiDAR edge bleed
static let visionMaxHz = 4                            // detection rate; decide loop stays at 10 Hz
static let visionSettleFrames = 3                     // persist before firing
static let visionHysteresisMeters = 0.3              // anti-flicker band at the threshold
static let visionRefractorySeconds = 1.0             // floor between cue state changes
```

Reuse the existing `proximityThresholdMeters` (1.8) for the fire gate and `dangerNearMeters` (0.5) for full intensity. Do not add parallel distance constants.

## SWIFT.md constraints this code must hold

- `PersonDetector` is an `actor`; all CoreML and pixel-buffer work stays off the main actor, only `PersonDetection?` crosses back. `PersonFusion` is `nonisolated` pure functions.
- No completion handlers; wrap `VNCoreMLRequest` in async. No `DispatchQueue` for app logic, use `Task`.
- No force unwrap or `try!` in committed code. The model load and every depth read fail safe: a bad frame yields `nil`, never a crash.
- `[weak self]` with `guard let self else { return }` in the frame callback.
- `os.Logger`, not `print`. One primary type per file. Group under `Perception/`.

## Test parity with Cole's Python

Cole's 17 tests are the contract. The 5 `test_ingest` tests cover the Wi-Fi wire format, which on-device fusion replaces, so they do not port. The 12 `test_pipeline` tests are pure fusion math and **must** port to `PersonFusionTests.swift` with identical inputs and expected outputs. When those 12 are green in Swift, the on-device math provably matches the proven Python.

## Risks and gates

- **Thermal is the demo-killer.** The one-ARSession decision, the 4 Hz throttle, and the degrade ladder all exist to protect it. Run the soak (it is already instrumented) before trusting the tier.
- **Coordinate mapping is the silent-bug risk.** Wrong orientation or a wrong Y-flip gives plausible boxes with wrong depth. The 12 ported tests plus a one-time on-device dimension assert close it.
- **Model export is a Cole dependency.** P0 blocks on the `.mlpackage`. If it slips, P1 can scaffold against any bundled YOLOv8n CoreML model and swap later.
- **Cut gate is real.** If P4 is not clean by H+12, ship the LiDAR-plus-direction demo and keep this tier dark. The base story stands without it.

## Sequenced for the hack window

1. P0 export + branch sync — unblocks everything, do it first.
2. P1 + P2 + the 12 ported tests — the core, gettable in one focused block.
3. P3 — wire to the seam, see the first real `0x10` tap.
4. P4 — discipline and thermal, the difference between a demo and a chatter.
5. Soak run, then P5 cut-gate decision.

When this lands, update `../STATUS.md`: move person-in-path from "in flight" to done, bump the latest commit, and add a session-log line.
