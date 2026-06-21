# HANDOFF — Citrus Squad phone app (Swift)

For the agent picking up the iOS app once the base structure compiles. Read this, then build in the order below. The design work is done; this is the runbook to implement against it.

Branch: `sam/ios-app-base`. The base was scaffolded here and this is where the phone-app work continues. Keep all code under `ios/Sources` and `ios/Tests`.

## Read order

1. This file.
2. [`docs/11-phone-app-design-spec.md`](docs/11-phone-app-design-spec.md) — the build contract. The bearing-to-bytes table and the ownership calls live here.
3. [`IOS-APP-PLAN.md`](IOS-APP-PLAN.md) — module map.
4. [`SWIFT.md`](SWIFT.md) — craft rules. Read before writing any Swift.
5. [`docs/03-protocol.md`](docs/03-protocol.md) and [`docs/04-phone-side.md`](docs/04-phone-side.md) — wire format and product behavior.
6. [`docs/12-perception-and-safety-design.md`](docs/12-perception-and-safety-design.md) — the LiDAR + camera safety tier. Read this before extending `DepthService` past sensing. It resolves how depth becomes a belt cue, the safety-over-direction arbitration, and the demo and thermal hardening.

## Where the base left off

Snapshot of `ios/` at handoff time. It is scaffolded but not yet committed (`git status` shows `?? ios/`).

Present:

- `ios/Project.yml` — XcodeGen source of truth. iOS 17, Swift 6, strict concurrency complete, team and bundle id set (`com.samuelgerungan.CitrusSquad`). Declares a `CitrusSquadTests` target.
- `ios/Sources/CitrusSquadApp.swift` — `@main`, shows `ControlPanelView()`.
- `ios/Sources/Info.plist` — three permission strings (location, motion, camera).

Does not compile yet, by design. Two reasons:

- `CitrusSquadApp` references `ControlPanelView`, which does not exist.
- `Project.yml` declares a `CitrusSquadTests` target with a `Tests/` source path that does not exist.

Not built yet: no `AppModel`, no services, no `Routing` / `Networking` / `Sensors` / `Replay` / `UI` folders.

## First five moves to a green build

Do these in order. They get the project compiling and runnable before any feature work.

1. **Create the feature folders** under `ios/Sources`: `Routing/`, `Sensors/`, `Networking/`, `Replay/`, `UI/`. Group by feature, not by kind (per `SWIFT.md`). `createIntermediateGroups` is already on in `Project.yml`.
2. **Add `AppModel`** at `ios/Sources/AppModel.swift` as `@MainActor @Observable final class`. Own it at the app entry in `CitrusSquadApp` and inject with `.environment(...)`. `ControlPanelView` reads it with `@Environment`.
3. **Add a minimal `ControlPanelView`** in `ios/Sources/UI/` so the missing symbol resolves and the app runs. A status placeholder is enough for now.
4. **Create `ios/Tests/`** with one real test file so the `CitrusSquadTests` target resolves. The `LC2Packet` golden-vector test once the codec exists, or a trivial passing test as a placeholder until then. Regenerate the project: `xcodegen generate`.
5. **Add `CitrusSquadConfig.swift`** with the constants from `docs/11`. Every module references it. No magic numbers scattered across files.

After these five, the app builds and runs on the demo phone. Then feature work begins.

## Build in milestone order

Each maps to a milestone in `docs/04-phone-side.md` and a done-bar in `docs/11`. Each step ships on its own and de-risks the next.

- **M0 — radio first.** `LC2Packet` and `LC2Transmitter` (`Networking/`). Fire a hardcoded turn-left packet at the ESP32 on the 100 ms heartbeat. Golden-vector test green. Belt twitches on command. This proves the link, the highest-risk unknown, before any routing exists.
- **M1 — heading.** Port `LocationService` for heading (`Sensors/`), apply the calibration offset. Body heading reads within ±10° while the phone is held still.
- **M2 — calibration.** Calibrate button in `ControlPanelView` records the offset. Two presses produce offsets within 2°.
- **M3 — routing math.** GPS plus `DirectionsClient` with a cached route. `Bearing` math matches a hand-computed sample within 1°.
- **M4 — quadrant mapper.** `quadrantFor` using the table in `docs/11`. All eight cardinal directions pass. Hysteresis holds at boundaries.
- **M5 — the ship line.** `RouteReplayer` plus a recorded route. Three clean walks of the demo loop with every turn cue firing on the correct side. This is "shippable in the demo."
- **M6 — optional bonus.** Step counting between fixes, fall detection, auto-recalibration on held-still.

If time runs short, the cut line is after M5's replay path. Replay plus a working belt is a complete story. Live Maps is the stretch the pitch discloses.

## Gotchas to handle, not rediscover

These are the traps the design pass already found. Each has a fix in `docs/11`.

- **Do not paste the probe code.** `wand-phone-probe`'s services are iOS-16 `ObservableObject` / `Combine` / `DispatchQueue`. Port the sensor configuration (the accuracy, the `headingFilter`, the `0.02` interval), rewrite the shell to `@Observable` plus strict concurrency. See `docs/11` "Porting the probe."
- **Camera permission describes a feature that does not exist.** `NSCameraUsageDescription` in `Info.plist` and `Project.yml` talks about a LiDAR obstacle sensor. Tier-2 does not use the camera. Recommend removing it so the demo shows one fewer permission prompt. See `docs/11` "Permissions."
- **Sequence byte is the transmitter's.** Not the route engine's. It increments every heartbeat tick, idle included, and wraps at 255.
- **Hysteresis is `RouteEngine` state.** `Bearing` stays pure. The deadband needs the previous quadrant.
- **One bearing-to-bytes table.** It is in `docs/11`. Use it verbatim. Do not re-derive the mapping from `03` and `04` separately, that is how the two drift.

## Branch and coordination

- Work on `sam/ios-app-base`. Code under `ios/Sources` and `ios/Tests` only.
- The design docs (`docs/`, root markdown) are the contract. If a spec is wrong or blocks you, flag it in the PR description or team chat. Do not silently fork the contract in code.
- Commits are imperative present tense per `CONTRIBUTING.md`. Squash-merge to `main` with a teammate skim.
- Run `xcodegen generate` after any `Project.yml` change or file add. Never commit the generated `.xcodeproj` (it is gitignored).

## Definition of done for the phone app

M5 green: the replay demo drives the belt, every turn cue fires on the correct side across three clean walks, there are no strict-concurrency warnings, and the `LC2Packet`, `Bearing`, and `RouteEngine` tests pass.

---

# CV Layer Handoff

Last updated: 2026-06-20

## What this covers

The Python computer vision layer for Citrus Squad. It ingests paired RGB + LiDAR depth frames streamed from the iPhone over a local WebSocket, runs YOLOv8n object detection, fuses each detection with its depth value, and broadcasts structured results to the haptic controller.

This doc is the handoff between Cole (CV layer) and Sam (LiDAR + Swift + haptics layer).

## Repo layout

```
server.py               start here to run the CV server
cv/
  __init__.py
  detection.py          DepthFusedDetection dataclass + NAVIGATION_CLASSES filter list
  pipeline.py           CVPipeline: transport-agnostic inference + depth fusion
  ingest.py             FastAPI app with /frames WebSocket + binary frame parser
  webcam_test.py        local smoke test -- runs the pipeline against the laptop webcam
tests/
  test_pipeline.py      12 unit tests for depth fusion logic
  test_ingest.py         5 unit tests for wire protocol parsing
requirements.txt
```

## Local webcam test

Before the iPhone is in the loop, you can verify the detection pipeline end-to-end against the laptop webcam:

```bash
python3 -m cv.webcam_test        # built-in camera
python3 -m cv.webcam_test 1      # external camera
```

Opens a live window with bounding boxes and prints each `DepthFusedDetection` dict to stdout. Depth values will read as a flat 2.0 m (no LiDAR on a laptop) -- that is expected. The important things to check are that boxes appear, labels are from the navigation class list, and `horizontal_norm` tracks objects left-to-right.

macOS: grant camera access to Terminal.app or whichever terminal you use (System Settings > Privacy & Security > Camera). VS Code's integrated terminal may not get the prompt -- run from Terminal.app if the camera fails to open.

Press `q` to quit the window.

## Running the server

```bash
pip3 install -r requirements.txt
python3 server.py
# or
uvicorn server:app --host 0.0.0.0 --port 8000
```

The server binds to `0.0.0.0:8000` so the iPhone and the haptic controller can both reach it over local Wi-Fi.

## WebSocket endpoints

### `/frames` (iPhone sender)

The iPhone app sends binary messages in this format:

```
[8 bytes]   float64   unix timestamp (seconds)
[4 bytes]   uint32    JPEG byte length N
[N bytes]             JPEG-encoded RGB frame
[4 bytes]   uint32    depth map rows H
[4 bytes]   uint32    depth map cols W
[H*W*4 bytes] float32  depth map, row-major, meters, NaN = no LiDAR return
```

Adjust the Swift sender to match this layout. The format is in `cv/ingest.py` (`_parse_frame`).

### `/haptics` (haptic controller)

Connect here to receive detection results. Each message is a JSON array sorted by closest obstacle first:

```json
[
  {
    "label": "person",
    "confidence": 0.91,
    "bbox_px": [312, 180, 540, 710],
    "depth_median_m": 1.43,
    "depth_min_m": 1.21,
    "horizontal_norm": 0.66,
    "timestamp_s": 1718000042.381
  }
]
```

| Field | Use |
|---|---|
| `depth_min_m` | Closest point of this obstacle. Drive haptic intensity from this. |
| `horizontal_norm` | 0.0 = full left, 1.0 = full right. Maps to belt motor position. |
| `label` | Optional: different buzz patterns per class (person vs. car). |
| `timestamp_s` | Drop results older than ~150ms to avoid acting on stale data. |

Empty array means no navigation-relevant obstacles this frame. No message is sent if there are no connected haptic clients.

## How depth fusion works

iPhone LiDAR depth maps are 256x192 at native resolution. RGB frames are 1280x720 or higher. The pipeline scales each YOLOv8 bounding box from RGB coordinates to depth coordinates, then samples the inner 50% of the scaled box (to avoid edge bleed where LiDAR returns cross object boundaries).

`depth_min_m` is the minimum valid depth in that crop window. `depth_median_m` is more stable across frames. For haptic intensity (how hard to buzz), use `depth_min_m`. For smoothing/filtering, use `depth_median_m`.

Zero and NaN depth values are both treated as missing (no LiDAR return). If the entire region is missing, both depth fields are `None`.

## Navigation classes

The model runs on all 80 COCO classes but only passes through classes relevant to pedestrian navigation. Current list in `cv/detection.py`:

```
person, bicycle, car, motorcycle, bus, truck,
chair, couch, dining table, bed,
stop sign, traffic light, fire hydrant,
bench, potted plant, dog, cat, backpack, suitcase, umbrella
```

Add or remove from `NAVIGATION_CLASSES` in `detection.py` to tune for the demo environment.

## Confidence threshold

Set to `0.35` in `CVPipeline.__init__`. Lower = higher recall (fewer missed obstacles, more false positives). For a navigation safety use case, err low. Raise it if the haptic belt buzzes too often on demo day.

## Model file

`yolov8n.pt` is downloaded automatically by ultralytics on first run. For the CoreML path, run:

```bash
python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml')"
```

This outputs `yolov8n.mlpackage`. Drag it into the Xcode target.

## Running tests

```bash
python3 -m pytest tests/ -v
```

All 17 tests pass. YOLO is mocked so no model download is needed to run tests.

## What is built

| File | Status | What it does |
|---|---|---|
| `cv/detection.py` | Done | `DepthFusedDetection` dataclass + `NAVIGATION_CLASSES` filter |
| `cv/pipeline.py` | Done | YOLOv8n inference + LiDAR depth fusion |
| `cv/ingest.py` | Done | FastAPI WebSocket server (`/frames` + `/haptics`) |
| `cv/webcam_test.py` | Done | Local smoke test against laptop webcam |
| `server.py` | Done | Uvicorn entry point |
| `tests/` | Done | 17 unit tests, all passing |
| `ios/Sources/Perception/ObjectDetectionService.swift` | Done (needs model) | CoreML inference + LiDAR fusion + motion tracking, settle/refractory, reports via `VisionHazardSource`. Exposes `movingObjects: [TrackedObject]` for Claude hook. |
| `ios/Sources/Perception/CollisionPredictor.swift` | Done | Pure threat/action logic; motion-aware `assess(tracked:bands:)` overload prioritizes approaching objects |
| `ios/Sources/Perception/MotionParameters.swift` | Done | `MotionState` + `TrackedObject` types; all classification thresholds in one place |
| `ios/Sources/Perception/MotionTracker.swift` | Done | Cross-frame object tracker; computes approach velocity + lateral rate; settle filter before confirming `MotionState` |

## On-device CoreML path (built — pending model file)

`ios/Sources/Perception/ObjectDetectionService.swift` is wired and compiling under Swift 6 strict concurrency. The Wi-Fi server still works as a fallback, but the demo target is everything on the phone.

**How it works:**

`DepthService` now exposes `onFrame: ((CVPixelBuffer, CVPixelBuffer?, BandDepths) -> Void)?` called on ARKit's serial queue at ~10 Hz. `ObjectDetectionService.start(depthService:hazard:)` registers this callback in `AppModel.init()` and loads the model async in the background.

Each callback:
1. Skips every other call (runs at ~5 Hz to stay off thermals)
2. Runs `VNCoreMLRequest` on `ARFrame.capturedImage` with `.right` orientation (corrects landscape sensor to portrait)
3. Filters to `navigationClasses` at ≥ 0.35 confidence
4. Maps each bounding box's horizontal center to the matching LiDAR band depth
5. Picks the nearest in-range detection and constructs a `Hazard`
6. Applies settle (3 consecutive frames) + refractory (10 frames, ~1 s) before calling `VisionHazardSource.report()` / `clear()`

`AppModel.currentHazard()` already polls `vision.currentHazard`, so the belt and arbitration require no changes.

**To activate (one-time):**

```bash
python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True)"
```

Drag `yolov8n.mlpackage` into the Xcode project Sources group and check "Add to target: CitrusSquad." The `nms=True` flag is required — without it the model outputs raw tensors instead of `VNRecognizedObjectObservation` and nothing will be detected.

Until the model is bundled, `objectDetection.modelLoaded` stays `false` and the service is silent (safe failure).

## Motion tracking layer (built)

`MotionParameters.swift` + `MotionTracker.swift` — parameter-based cross-frame tracking, no AI.

**Philosophy:** same approach as the Mira project. Explicit named thresholds in `MotionParameters`, no model, fully testable by feeding synthetic frame sequences. Claude fires only when `motionState == .approaching`; stationary objects never touch Claude.

**How it works:**

Each pipeline frame, `ObjectDetectionService` passes the `[CVDetection]` array to `MotionTracker.update(detections:frameIndex:)`. The tracker:

1. Matches each detection to an existing track by label + horizontal proximity (within `matchRadiusNorm = 0.15`)
2. Appends depth and horizontal position to per-object ring buffers (6 frames deep)
3. Computes approach rate `(oldest_depth - newest_depth) / elapsed` and lateral rate
4. Classifies: approaching if rate ≥ 0.15 m/s, moving if lateral rate ≥ 0.04 norm/s, else stationary
5. Applies a settle filter (3 consecutive matching frames before confirming)
6. Expires tracks not seen for 8 frames

Returns `[TrackedObject]` with `motionState`, `approachRateMetersPerSecond`, and `lateralRateNormPerSecond` per object.

**Tuning:** all thresholds are in `MotionParameters.swift` with named constants. Change a value, rebuild, test. No model retraining.

**Claude hook:** `ObjectDetectionService.movingObjects: [TrackedObject]` is exposed on the `@MainActor` and contains only `approaching` and `moving` objects. Wire Claude identification here when ready — stationary objects are excluded by design.

## Collision prediction and action layer (built)

`ios/Sources/Perception/CollisionPredictor.swift` — pure logic, no sensors, no side effects.

**Types shipped:**

```swift
enum ThreatLevel: Sendable { case none, advisory, warning, urgent }

enum NavigationAction: Sendable, Equatable {
    case clear
    case stepLeft(paces: Int)
    case stepRight(paces: Int)
    case stop
    case slowDown
}

struct ObstacleThreat: Sendable {
    var label: String
    var distanceMeters: Double
    var horizontalNorm: Double   // 0.0 = far left, 1.0 = far right
    var level: ThreatLevel
    var action: NavigationAction
}

struct CVDetection: Sendable {
    var label: String
    var confidence: Float
    var horizontalNorm: Double
    var distanceMeters: Double   // -1 if unknown
}
```

**`CollisionPredictor.assess(detections:bands:)`** — entry point. Fuses LiDAR band depths into each detection, filters to things within 5 m, picks the nearest, grades it, and picks a dodge direction by checking which LiDAR band has clear space.

`AppModel.objectDetection.currentThreat` exposes the latest `ObstacleThreat?`. Josh's audio layer can read it from there and speak "person ahead, step left 2 paces."

**Concrete example (pole at 2 m, dead center):**
```
horizontal_norm = 0.51  → center band → centerMass mask
depth = 2.0 m           → warning
left LiDAR band: clear  → stepLeft(paces: 1)

Belt fires: centerMass tap
Audio can say: "pole ahead, step left 1 pace"
```

## Open items

- [x] Implement `ObjectDetectionService.swift` (CoreML + ARKit frame subscription via `DepthService.onFrame`)
- [x] Implement `CollisionPredictor.swift` — pure threat/action logic; motion-aware `assess(tracked:bands:)` overload
- [x] Implement `MotionParameters.swift` — parameter library for motion classification
- [x] Implement `MotionTracker.swift` — cross-frame object tracker, approach velocity, settle filter
- [x] Wire `ObjectDetectionService` into `AppModel` (`objectDetection.start(depthService:hazard:)` in `init`)
- [ ] Export `yolov8n.mlpackage` and add to Xcode target (one-time: `python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True)"`, drag into Sources group, check "Add to target")
- [ ] Confirm ARKit depth map x-axis = left/right in portrait mount. Walk toward something on the left, verify `depth.left` drops and belt fires left.
- [ ] Tune `MotionParameters` thresholds on real footage — `approachThresholdMetersPerSecond` and `matchRadiusNorm` are the most likely to need adjustment
- [ ] Wire Claude identification for `movingObjects` — hook is `objectDetection.movingObjects: [TrackedObject]` on the main actor; only approaching + moving objects are included
- [ ] Confirm `VNRecognizedObjectObservation` output from the CoreML model — requires NMS export. If nothing is detected, re-export with `nms=True`
- [ ] Confirm wire format between Python server and iOS sender if Wi-Fi path is kept as fallback
