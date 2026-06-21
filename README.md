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
- **`cv/detection.py`** — `DepthFusedDetection` dataclass and the `NAVIGATION_CLASSES` filter (21 pedestrian-relevant COCO classes: person, bicycle, car, bench, parking meter, etc.). The on-device iOS filter (`CitrusSquadConfig.visionNavigationClasses`) mirrors this set so both recognize the same things.
- **`cv/ingest.py`** — FastAPI WebSocket server. Accepts binary frame pairs from the iPhone over local Wi-Fi, runs the pipeline, and broadcasts JSON detections to any connected haptic client.
- **`cv/webcam_test.py`** — local smoke test. Runs the pipeline against a laptop webcam with a synthetic 2.0m depth plane so the full detection path can be verified without a phone.
- **`server.py`** — entry point (`uvicorn server:app --host 0.0.0.0 --port 8000`).
- **`tests/`** — 17 unit tests covering depth fusion math and the wire protocol parser.

### Planned: on-device CoreML path (no Wi-Fi required)

The Wi-Fi server works for prototyping but has a single point of failure at demo time. The target is to run everything on the phone:

1. Export `yolov8n.mlpackage` from the Python model (`YOLO("yolov8n.pt").export(format="coreml")`).
2. **`ObjectDetectionService.swift`** — subscribes to the ARKit session already running in `DepthService`. Each `ARFrame` carries both the camera image and the LiDAR depth map. Runs `VNCoreMLRequest` on the camera image, scales bounding boxes to depth coordinates, samples the inner 50% of each box (same as the Python fusion logic), and calls `VisionHazardSource.report()` with the result.
3. No Wi-Fi dependency. No laptop. All inference runs on the Neural Engine.

### Planned: collision prediction and action layer

Pure-logic layer on top of raw detections. For each detection, it asks: is this object in my path, how close, and what is the best move?

```
Input:  DepthFusedDetection list + LiDAR band readings
Output: NavigationAction (StepLeft(paces: 2), StepRight(paces: 1), Stop, SlowDown, Clear)
```

Decision factors: horizontal position (is it centered?), distance (how urgent?), object type (static pole vs. moving person), and which side has more open space. Belt fires the directional tap; Josh's audio layer can say "pole ahead, step left 2 paces."

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
  YOLOv8n CoreML (planned)   -> object ID + action  renders the event as a
        |                                            servo pattern
        v  arbitrate (safety > direction)
  one LC2 packet / 100 ms  --UDP over Wi-Fi-->  4 servos: Far L, L, R, Far R
```

## Team

Sam (iOS, LiDAR, ESP32, CoreML iOS integration), Cole (computer vision, Python pipeline, collision prediction), Josh (audio), Angelo.

## License

MIT.
