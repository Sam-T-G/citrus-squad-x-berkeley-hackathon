# Citrus Squad × Berkeley AI Hackathon 2026

Citrus Squad's entry for the **Berkeley AI Hackathon 2026** at the MLK Jr. Building, UC Berkeley. Hack window opens Saturday June 20 at 11:00 AM and runs 24 hours, closing Sunday June 21 at 11:00 AM. Judging and closing ceremony follow.

**Citrus Squad** is a haptic navigation belt for blind and low-vision wearers. A chest-mounted iPhone reads compass direction and Google Maps turn cues, detects nearby obstacles via LiDAR, identifies objects via on-device computer vision, and taps four servos on a belt to tell the wearer which way to turn or move. No screen. No audio required. The phone is the brain; an ESP32 drives the belt.

## Run it yourself

Every teammate runs their own instance on their own phone and Mac. See **[RUNNING.md](RUNNING.md)** for the ten-minute setup. The short version:

```sh
./ios/setup.sh           # installs XcodeGen, creates your local signing, generates the project
open ios/CitrusSquad.xcodeproj
# set your team + bundle id in ios/Local.xcconfig, pick your iPhone, press Cmd-R
```

You can run the full app with just a phone (the Navigation card's demo route + simulate mode needs no belt and no API key). The ESP32 belt and live Google Maps are optional add-ons covered in RUNNING.md.

## Computer vision layer (Cole — `cole/computer-vision`)

The CV layer adds object awareness on top of the LiDAR obstacle detection already in the base app. It identifies what is in the path (pole, person, car, bench) and feeds that into the same hazard arbitration system that already drives the belt.

### What is built

- **`cv/pipeline.py`** — transport-agnostic YOLOv8n inference fused with LiDAR depth. Takes a paired (RGB frame, depth map) and returns a list of `DepthFusedDetection` objects: label, confidence, bounding box, depth at the box, and horizontal position normalized 0–1.
- **`cv/detection.py`** — `DepthFusedDetection` dataclass and the `NAVIGATION_CLASSES` filter (20 pedestrian-relevant COCO classes: person, bicycle, car, pole, bench, etc.).
- **`cv/ingest.py`** — FastAPI WebSocket server. Accepts binary frame pairs from the iPhone over local Wi-Fi, runs the pipeline, and broadcasts JSON detections to any connected haptic client.
- **`cv/webcam_test.py`** — local smoke test. Runs the pipeline against a laptop webcam with a synthetic 2.0m depth plane so the full detection path can be verified without a phone.
- **`server.py`** — entry point (`uvicorn server:app --host 0.0.0.0 --port 8000`).
- **`tests/`** — 17 unit tests covering depth fusion math and the wire protocol parser.

### On-device CoreML path (built, pending model file)

All inference runs on the phone. No Wi-Fi dependency, no laptop at demo time.

- **`ios/Sources/Perception/ObjectDetectionService.swift`** — hooks into `DepthService.onFrame` (10 Hz). Runs `VNCoreMLRequest` on the ARKit camera frame at 5 Hz, fuses each detected bounding box with the LiDAR band depth at that horizontal position, runs motion tracking, applies a settle filter (3 consecutive frames before firing) and a refractory period (~1 s after clearing), then calls `VisionHazardSource.report()` to feed the existing tick loop. Exposes `movingObjects: [TrackedObject]` on the main actor as the Claude identification hook.
- To activate: export the model and drag it into Xcode. One command: `python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True)"`, then drag `yolov8n.mlpackage` into the Xcode project Sources group and check "Add to target: CitrusSquad." Until then the service starts but `modelLoaded` stays false and no detections fire.

### Motion tracking layer (built)

Parameter-based cross-frame object tracking. No AI. Explicit thresholds in one file, fully testable.

- **`ios/Sources/Perception/MotionParameters.swift`** — defines `MotionState` (`unknown / stationary / moving / approaching / receding`), `TrackedObject`, and all classification thresholds (`approachThresholdMetersPerSecond`, `lateralThresholdNormPerSecond`, `settleFrames`, etc.). Tune values here against real footage; no code changes needed elsewhere.
- **`ios/Sources/Perception/MotionTracker.swift`** — tracks YOLO detections across frames by label + horizontal proximity. Maintains per-object depth and position history, computes approach velocity and lateral rate, and applies a settle filter before confirming `MotionState`. Stationary objects are never elevated — LiDAR handles those. Approaching objects are the only ones passed to Claude.

### Collision prediction and action layer (built)

Pure-logic layer on top of raw detections. No sensors, fully unit-testable.

- **`ios/Sources/Perception/CollisionPredictor.swift`** — for each detection, asks: is this object in my path, how close, and what is the best move? Motion-aware overload `assess(tracked:bands:)` promotes approaching objects one threat tier and suppresses stationary CV detections beyond warning range.

```
Input:  [TrackedObject] + LiDAR BandDepths
Output: ObstacleThreat (label, distance, ThreatLevel, NavigationAction)
```

`ThreatLevel`: `advisory` (3–5 m), `warning` (1.5–3 m), `urgent` (< 1.5 m). `NavigationAction`: `stepLeft(paces:)`, `stepRight(paces:)`, `stop`, `slowDown`, `clear`. Checks which LiDAR band has clear space to decide which way to dodge. Belt fires the directional tap; Josh's audio layer can speak "person ahead, step left 2 paces."

### Running the Python CV server

```sh
pip3 install -r requirements.txt
python3 server.py
# or: uvicorn server:app --host 0.0.0.0 --port 8000
```

Smoke-test the detection pipeline locally (no phone needed):

```sh
python3 -m cv.webcam_test        # built-in camera
python3 -m cv.webcam_test 1      # external camera
```

Run the unit tests:

```sh
python3 -m pytest tests/ -v
```

## System architecture

```
iPhone (Citrus Squad app)                         ESP32 (belt)
  Maps directions + compass  -> turn cue            receives one LC2 packet
  LiDAR scene depth          -> obstacle cue        per 100 ms heartbeat,
  YOLOv8n CoreML              -> object ID + action  renders the event as a
        |                                            servo pattern
        v  arbitrate (safety > direction)
  one LC2 packet / 100 ms  --UDP over Wi-Fi-->  4 servos: Far L, L, R, Far R
```

## Team

Sam (iOS, LiDAR, CoreML iOS integration), Cole (computer vision, Python pipeline, collision prediction), Josh (audio), Gelo (hardware: belt construction, phone harness, ESP32 wiring and firmware).

## License

MIT.
