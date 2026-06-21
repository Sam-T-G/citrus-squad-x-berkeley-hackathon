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

Last updated: 2026-06-20 (updated mid-hack)

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

## Object identification gap

**What YOLO can identify:** the 80 COCO classes — people, bikes, cars, chairs, benches, bags, animals, etc.

**What YOLO cannot identify:** poles, bollards, trash cans, street lights, parking meters, fire hydrants (beyond the COCO one), construction barriers. These are the objects blind pedestrians most commonly walk into.

**Why the parameter library doesn't fix this:** `MotionParameters` classifies motion, not object type. It tells you a detected object is approaching — it cannot tell you what that object is. And it only runs on top of what YOLO already found. If YOLO doesn't detect a pole, the parameter library never sees it.

**What handles unidentified stationary objects today:** LiDAR. It fires the belt tap regardless of object type — it just can't produce a spoken label. The wearer knows something is close on a specific side but not what it is.

**The gap for a blind user:** the audio label matters. "Pole on your left" is more useful than a tap with no context. Without identification, the belt tells you *where* but not *what*.

## Claude Vision integration (planned for demo)

**Decision:** use Claude Vision to identify stationary objects detected by LiDAR, and moving objects tracked by `MotionTracker`. The belt fires immediately from LiDAR distance (on-device, instant). Claude names the object afterward for the audio layer — fire and forget, never blocks the belt.

**Approach rate and latency:** Haiku 4.5 with a small cropped image returns in ~300-500ms over Wi-Fi. By the time text-to-speech finishes speaking, the round trip is ~700ms. Acceptable for audio narration; unacceptable for belt timing (which is why Claude never touches belt logic).

**Demo strategy — pre-cache scout mode:** for a blind user, network latency during the demo is a reliability risk. The planned approach is to walk the demo route beforehand with the app running, identify and cache every stationary object on the path via Claude, then during the actual demo speak all labels from cache instantly with zero network dependency.

```
Scout pass (before demo):
  LiDAR fires → Claude Vision → "trash can" → cache at (band: center, dist: ~2.1m)

Demo:
  LiDAR fires → cache hit → audio says "trash can on your left" instantly
```

**What still needs building:**
- `SceneCache.swift` — stores identified objects by horizontal band + approximate distance. Keyed loosely (±0.5m, same band) so small position variance still hits.
- `ClaudeVisionIdentifier.swift` — crops `ARFrame.capturedImage` at the LiDAR band position, sends to Haiku 4.5, returns a plain-English label. Called once per new detection, result written to `SceneCache`.
- Wire into `AppModel` tick loop: on new LiDAR hazard, check cache first, call Claude if miss.
- Audio layer reads the label from the cache and speaks it.

**Post-hackathon:** replace Claude Vision with an on-device CoreML model trained on Mapillary Vistas or Open Images V7 (600+ classes including street infrastructure). Same architecture, no network dependency, works everywhere.

## Claude Vision pipeline options (latency analysis)

Four approaches, ranked by complexity:

**1. Direct phone → Claude API**
iPhone calls the Anthropic API directly. Crop the camera frame to the hazard region, resize small, send to Haiku 4.5.
- Latency: ~300-500ms on good Wi-Fi
- Complexity: lowest — one URLSession call
- Risk: demo venue Wi-Fi dependency. If it drops, no labels (belt still works)
- API key lives in `Local.xcconfig` same as the GitHub token

**2. Direct + location cache (best latency after first detection)**
Same as above but cache the label by horizontal band + approximate distance. If LiDAR fires at center-band ~2m again, speak the cached label instantly instead of calling Claude again. Most objects at the demo site won't move.

```
First time:  LiDAR fires → call Claude → "trash can" → cache it
Next time:   LiDAR fires → cache hit → speak instantly (~0ms)
```

After a few seconds of walking the same space, almost everything is cached. This is the highest-impact optimization.

**3. Phone → local Mac proxy → Claude API**
Phone sends the cropped image to a small server on the Mac over local Wi-Fi. Mac calls Claude, returns the label. `cv/ingest.py` already exists and could handle this.
- Adds ~1ms for the local hop, saves nothing vs option 1
- Only worth it if the Mac is in the loop for monitoring or logging anyway

**4. Pre-identify the demo environment (zero latency)**
Walk the demo route beforehand with the app running. Identify and cache every stationary object on the path. By demo time, nothing calls Claude during the actual demo — all cache hits.
- Zero latency during demo
- Only works if the environment is fixed and you can scout it first
- Very viable for a controlled demo loop

**Decision for the hackathon: options 1 + 2 together, with option 4 as the demo safety net.**

Direct API call for new detections, cache hits for anything seen before. Scout the route beforehand to pre-populate. If the cache covers everything on the demo path, Claude is never called live.

**Why audio reliability matters more for a blind user:**

For a sighted person demoing the tech, a 400ms delay or a dropped Wi-Fi label is fine. For someone actually navigating, it isn't. The belt tap from LiDAR is the safety signal — it fires instantly, on-device, no network. The audio label is context ("trash can on your left"). If the label is slow or missing, the user still knows something is there and which side. But the label is how they decide whether to dodge or just walk past.

The scout + cache strategy (option 4) is the honest demo story: the system narrates the environment in real time with zero visible network dependency because it already knows what's there.

**Post-hackathon target:** replace Claude Vision with an on-device CoreML model (Mapillary Vistas or Open Images V7, 600+ classes including street infrastructure). No network, no latency, works everywhere.

## CV model landscape — what else exists and why we're not switching today

Research as of 2026-06-20. Framed against the actual constraint: on-device CoreML, thermal budget is the #1 demo risk, ~5 Hz, and LiDAR already owns "where something is." CV's real job is "what is it."

### The actual gap

The problem is vocabulary, not accuracy. YOLOv8n finds COCO movers (person, car, bike, dog) well enough, and LiDAR fires the belt regardless of class. COCO's 80 classes don't include poles, bollards, trash cans, parking meters, street lights, construction barriers, or curbs, which are what blind pedestrians actually walk into. The model comparison below weights on street-infrastructure class coverage and thermal fit, not raw mAP.

### Model families

**Newer closed-set YOLO (v11n / v12n).** Drop-in upgrades. YOLOv12-S hits 48.0% mAP at 2.6 ms/image, ~1% better than v11 at equal latency. Nano variants stay CoreML-friendly. Ships the same 80 COCO classes. Upgrading gets you a small speed and accuracy bump and zero new street-infrastructure labels. Lowest effort, lowest payoff for the gap.

**Open-vocabulary detectors (YOLO-World / YOLOE, Grounding DINO).** These take a text vocabulary at export time, so you can ask for "bollard, trash can, parking meter" without retraining. YOLO-World's "prompt-then-detect" bakes the embeddings into the weights before export, so the text encoder is gone at inference and speed stays real-time (~35 AP on LVIS at 52 FPS on V100; small variant ~10 ms on edge). Most direct fix for the vocabulary gap in theory. Friction: CoreML export of YOLO-World is fiddly (RepVL-PAN doesn't always convert clean), the smallest variant is "small" (~12M params vs v8n's 3M), and you can't change the vocabulary at runtime. Grounding DINO is stronger open-vocab but too heavy for the phone at all.

**Street-scene segmentation (Mapillary Vistas / Cityscapes).** The family actually built for the domain. Mapillary Vistas has 124 classes: pole, utility pole, street light, curb, curb cut, crosswalk, traffic sign front/back, traffic light variants. Cityscapes covers ~19 classes (road, sidewalk, pole, sign, person). Real-time edge models exist: SegFormer-B0 (3.8M params, 76.2% mIoU on Cityscapes, 47 FPS at 512px) and PIDNet-S (78.6% mIoU at 93 FPS on Cityscapes), with a 2025 PIDNet-LW cutting params 47%. Output is per-pixel masks, not labeled boxes, so fusing with LiDAR bands and the `TrackedObject` pipeline is more integration work. No polished off-the-shelf CoreML package. This is the strong post-hackathon target, not a Saturday-night swap.

**VLM identification (Claude Vision, current plan).** Open vocabulary by description, best label quality, zero training. Haiku 4.5 at ~300-500ms over Wi-Fi with scout+cache as the demo safety net. Only weakness is network dependency, already neutralized by the scouting strategy.

### Recommendation

**Updated 2026-06-20.** YOLO-World is now implemented on `cole/computer-vision` — this is no longer a timebox experiment. The export is done, the Swift wiring is done, and the fallback to v8n is automatic. What remains is getting it onto the demo branch and through the thermal gate. See the implementation status section below.

### Summary table

| Model / approach | Paradigm | Street-infra coverage | On-device CoreML | Latency (nano/edge) | New labels without retrain | Hackathon fit |
|---|---|---|---|---|---|---|
| YOLOv8n (current) | Closed-set det | COCO 80 — no poles/bollards/cans | Yes, proven | ~5 Hz wired | No | Baseline, keep |
| YOLOv11n / v12n | Closed-set det | Same COCO 80 | Yes, CoreML-friendly | ~2.6 ms/img (S) | No | Easy bump, low payoff |
| YOLO-World / YOLOE | Open-vocab det (frozen at export) | Any prompted class | Possible, export fiddly, runs hotter | ~10 ms edge (S) | Yes, at export time | Risky, worth a timebox |
| RT-DETR / RF-DETR | Transformer det | COCO/custom | Heavier, export harder | Slower than v12 on edge | No unless trained | Skip |
| Mapillary Vistas seg | Semantic/instance seg | Best: 124 classes incl pole, curb, crosswalk, street light | Convertible, you build it | Seg is heavier | No (pretrained on these classes) | Post-hack target |
| Cityscapes seg (SegFormer-B0 / PIDNet) | Semantic seg | ~19 classes: road, sidewalk, pole, sign | Yes, real-time edge models exist | 47 FPS @ 512 (SegFormer-B0) | No | Post-hack option |
| Open Images V7 detector | Closed-set det | 600 classes, good street coverage | Convertible, you build it | Depends on backbone | No | Post-hack option |
| Grounding DINO | Open-vocab det | Excellent | No, too big | Server-only | Yes | Server fallback only |
| Claude Vision (Haiku 4.5) | VLM identify | Unlimited by description | Network only | ~300-500ms + TTS | Yes | Best gap-filler now |
| Apple Vision built-in | Detect/classify | Animals only (cats/dogs) | Yes, native | Fast | No | Not useful here |

## YOLO-World implementation status

Built and pushed on `cole/computer-vision` (commit `30a5fba`, 2026-06-20).

### What's done

**Export.** `yolov8s-worldv2.mlpackage` exported on Python 3.11 with ultralytics 8.4.72 and coremltools 9.0. The export must run on Python 3.11 — Python 3.14 throws `BlobWriter not loaded` (a known coremltools incompatibility). SSL certificate errors during download are worked around with `ssl._create_default_https_context = ssl._create_unverified_context` before the import.

The exported model is a CoreML pipeline (two steps: `mlProgram` + `nonMaximumSuppression`) with `confidence` and `coordinates` multiarray outputs. Vision reads these and returns `VNRecognizedObjectObservation`, same as v8n. The NMS step embeds 80 class labels: the first 20 are the navigation vocabulary, slots 21-80 are numbered ("20", "21", …) as padding from the fixed-size output tensor. The `visionNavigationClasses` filter in Swift drops the numbered slots.

**Navigation vocabulary (frozen at export — changing it requires a re-export):**
```
person, bicycle, car, motorcycle, bus, truck, dog, cat,
pole, bollard, trash can, garbage bin, parking meter, street light,
fire hydrant, traffic cone, construction barrier, bench, stop sign, traffic light
```

**Swift wiring.** Three changes from the v8n baseline:

- `CitrusSquadConfig` — new constants: `visionModelName = "yolov8s-worldv2"`, `visionFallbackModelName = "yolov8n"`, `visionThrottleDivisor = 3` (~3.3 Hz vs v8n's 5 Hz, accounting for the heavier model), and `visionNavigationClasses` as the single source of truth for the frozen vocabulary.
- `ObjectDetectionService.loadModel()` — tries `visionModelName` first (both `.mlmodelc` and `.mlpackage` extensions), falls back to `visionFallbackModelName`. Logs which one loaded. Silent on failure — safe, belt runs on LiDAR.
- `ObjectDetectionService.runDetection()` — filters against `CitrusSquadConfig.visionNavigationClasses` instead of the old hardcoded COCO set.

**Model files.** Both `.mlpackage`s live in `ios/Sources/Resources/` (gitignored). `ios/Sources/Resources/.gitkeep` has the exact regeneration commands. XcodeGen picks up the directory automatically from `sources: path: Sources` — no manual `Project.yml` edits needed.

### What's needed to run it

**1. Get Cole's files onto the demo branch (Sam).**

The demo branch (`sam/ios-app-base`) runs `PersonDetector`, not `ObjectDetectionService`. `cole/computer-vision` has `ObjectDetectionService`, `MotionTracker`, `MotionParameters`, `CollisionPredictor`, and the new `CitrusSquadConfig` constants. The committed path is in `ios/PERCEPTION-AVOIDANCE-HANDOFF.md` Part B: bring those four Perception files onto the demo branch and make `ObjectDetectionService` the one detector. Keep `PersonDetector`'s time-based gate logic as the reference for reconciling the hysteresis.

**2. Regenerate the model files locally (Sam, one-time).**

Models are gitignored. On the demo branch after the merge, run the commands from `.gitkeep`:

```bash
# from repo root, using Python 3.11
python3.11 -c "
import ssl; ssl._create_default_https_context = ssl._create_unverified_context
from ultralytics import YOLOWorld
model = YOLOWorld('yolov8s-worldv2.pt')
model.set_classes(['person','bicycle','car','motorcycle','bus','truck','dog','cat',
  'pole','bollard','trash can','garbage bin','parking meter','street light',
  'fire hydrant','traffic cone','construction barrier','bench','stop sign','traffic light'])
model.export(format='coreml', nms=True)
"
mv yolov8s-worldv2.mlpackage ios/Sources/Resources/

# fallback v8n
python3.11 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True)"
mv yolov8n.mlpackage ios/Sources/Resources/
```

**3. Regenerate the Xcode project (Sam).**

```bash
cd ios && xcodegen generate
```

XcodeGen scans `Sources/` and picks up both `.mlpackage` directories as CoreML resources automatically. No manual Xcode drag needed.

**4. Run the thermal soak (Sam, before trusting the world model).**

The world model is ~4x heavier than v8n (~12M vs 3M parameters). The soak procedure is in `docs/12` §6. Run it first on v8n to get a baseline, then with the world model at `visionThrottleDivisor = 3` (~3.3 Hz). If it can't hold out of `.serious` thermal state at 3 Hz, raise the divisor to 4 or 5 and retest. If it can't hold at any safe Hz, keep the world model as the scout-mode-only tool and run v8n live.

**5. Confirm orientation calibration (Sam, on-device).**

`ObjectDetectionService.runDetection` passes `.right` orientation to `VNImageRequestHandler`. Verify this is correct for the chest-mount angle: walk toward something on the left, confirm the belt fires left and `depth.left` drops. One bench test closes this.

**6. Complete Parts B–D from `ios/PERCEPTION-AVOIDANCE-HANDOFF.md` (Sam).**

The YOLO-World swap is Part A of the full end-to-end pipeline. Parts B–D bring the motion/collision layers, the `PerceptionSnapshot` AI context object, and the Claude avoidance advisor. The belt story is whole at Part B; D1/D2 are the pitch's wow layer.

### Vocabulary is frozen — changing it requires a re-export

The class list is baked into the model weights at `set_classes()` time. If a class is missing from the demo environment, update the list in `CitrusSquadConfig.visionNavigationClasses` (the Swift filter) **and** re-run the export with the same updated list. Both must stay in sync or the filter drops valid detections.

### Fallback is automatic

If `yolov8s-worldv2.mlpackage` is not in the bundle, `ObjectDetectionService` loads `yolov8n.mlpackage` silently. The belt and LiDAR path never go dark. The only difference is narrower vocabulary (COCO 80 vs the navigation set) and faster inference.

## Open items

### Cole's lane (done)
- [x] Implement `ObjectDetectionService.swift` (CoreML + ARKit frame subscription via `DepthService.onFrame`)
- [x] Implement `CollisionPredictor.swift` — pure threat/action logic; motion-aware `assess(tracked:bands:)` overload
- [x] Implement `MotionParameters.swift` — parameter library for motion classification
- [x] Implement `MotionTracker.swift` — cross-frame object tracker, approach velocity, settle filter
- [x] Wire `ObjectDetectionService` into `AppModel` (`objectDetection.start(depthService:hazard:)` in `init`)
- [x] Export `yolov8s-worldv2.mlpackage` with 20-class navigation vocabulary (`python3.11`, `nms=True`, validated as pipeline). Both models in `ios/Sources/Resources/` with regeneration commands in `.gitkeep`.
- [x] Update `CitrusSquadConfig` — `visionModelName`, `visionFallbackModelName`, `visionThrottleDivisor`, `visionNavigationClasses`
- [x] Update `ObjectDetectionService` — model loading with fallback, config-driven throttle and vocabulary filter

### To activate YOLO-World on the demo branch (Sam)
- [ ] Merge `ObjectDetectionService`, `MotionTracker`, `MotionParameters`, `CollisionPredictor`, and the new `CitrusSquadConfig` vision constants from `cole/computer-vision` onto `sam/ios-app-base` (Part B of `ios/PERCEPTION-AVOIDANCE-HANDOFF.md`). Reconcile the gate: port `PersonDetector`'s time-based hysteresis into `ObjectDetectionService`'s settle path.
- [ ] Regenerate model files locally on the demo branch (`python3.11`, commands in `ios/Sources/Resources/.gitkeep`) and run `xcodegen generate`
- [ ] Run thermal soak on v8n first (procedure in `docs/12` §6), then again with world model at `visionThrottleDivisor = 3`. If world model runs hot, raise divisor or keep it as scout-mode-only.
- [ ] Confirm `.right` orientation calibration on-device — walk toward something on the left, verify `depth.left` drops and belt fires left

### Claude avoidance layer (Parts C + D, Sam + Josh)
- [ ] Build `PerceptionSnapshot.swift` — structured scene value (three bands, labels, motion, route) with XML serialization for Claude. Spec in `ios/PERCEPTION-AVOIDANCE-HANDOFF.md` Part C.
- [ ] Build `AvoidanceAdvisor.swift` — threat → snapshot → Claude draft+verify → `AudioCueSink`. Fire-and-forget, never on the belt path. Part D1.
- [ ] Build `SceneCache.swift` — loosely-keyed label/avoidance cache (band + approximate distance + label). Pre-warm on the scout pass.
- [ ] Wire `VoiceCommand.describe_surroundings()` to read `PerceptionSnapshot`. Part D2 (pull path).
- [ ] Scout the demo route to pre-populate `SceneCache` before judging

### Tuning (on real footage)
- [ ] Tune `MotionParameters` thresholds — `approachThresholdMetersPerSecond` and `matchRadiusNorm` most likely to need adjustment
- [ ] Test vocabulary synonyms against `cv/webcam_test.py` — confirm "trash can" vs "trashcan", "pole" vs "signpost" on demo-site footage. Vocabulary is frozen at export; if a synonym works better, re-export.
