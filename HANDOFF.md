# WAND CV Layer Handoff

Last updated: 2026-06-20

---

## What this covers

The Python computer vision layer for WAND. It ingests paired RGB + LiDAR depth frames streamed from the iPhone over a local WebSocket, runs YOLOv8n object detection, fuses each detection with its depth value, and broadcasts structured results to the haptic controller.

This doc is the handoff between Cole (CV layer) and Sam
 (LiDAR + Swift + haptics layer).

---

## Repo layout

```
server.py               start here to run the CV server
cv/
  __init__.py
  detection.py          DepthFusedDetection dataclass + NAVIGATION_CLASSES filter list
  pipeline.py           CVPipeline: transport-agnostic inference + depth fusion
  ingest.py             FastAPI app with /frames WebSocket + binary frame parser
scripts/
  export_yolov8_coreml.py  one-time script to export yolov8n.mlpackage for Sam
  
tests/
  test_pipeline.py      12 unit tests for depth fusion logic
  test_ingest.py         5 unit tests for wire protocol parsing
requirements.txt
```

---

## Running the server

```bash
pip3 install -r requirements.txt
python3 server.py
# or
uvicorn server:app --host 0.0.0.0 --port 8000
```

The server binds to `0.0.0.0:8000` so the iPhone and Sam
's haptic controller can both reach it over local Wi-Fi.

---

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

### `/haptics` (Sam
's haptic controller)

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

**Fields Sam
 needs:**

| Field | Use |
|---|---|
| `depth_min_m` | Closest point of this obstacle. Drive haptic intensity from this. |
| `horizontal_norm` | 0.0 = full left, 1.0 = full right. Maps to belt motor position. |
| `label` | Optional: different buzz patterns per class (person vs. car). |
| `timestamp_s` | Drop results older than ~150ms to avoid acting on stale data. |

Empty array means no navigation-relevant obstacles this frame. No message is sent if there are no connected haptic clients.

---

## How depth fusion works

iPhone LiDAR depth maps are 256x192 at native resolution. RGB frames are 1280x720 or higher. The pipeline scales each YOLOv8 bounding box from RGB coordinates to depth coordinates, then samples the inner 50% of the scaled box (to avoid edge bleed where LiDAR returns cross object boundaries).

`depth_min_m` is the minimum valid depth in that crop window. `depth_median_m` is more stable across frames. For haptic intensity (how hard to buzz), use `depth_min_m`. For smoothing/filtering, use `depth_median_m`.

Zero and NaN depth values are both treated as missing (no LiDAR return). If the entire region is missing, both depth fields are `None`.

---

## Navigation classes

The model runs on all 80 COCO classes but only passes through classes relevant to pedestrian navigation. Current list in `cv/detection.py`:

```
person, bicycle, car, motorcycle, bus, truck,
chair, couch, dining table, bed,
stop sign, traffic light, fire hydrant,
bench, potted plant, dog, cat, backpack, suitcase, umbrella
```

Add or remove from `NAVIGATION_CLASSES` in `detection.py` to tune for the demo environment.

---

## Confidence threshold

Set to `0.35` in `CVPipeline.__init__`. Lower = higher recall (fewer missed obstacles, more false positives). For a navigation safety use case, err low. Raise it if the haptic belt buzzes too often on demo day.

---

## Model file

`yolov8n.pt` is downloaded automatically by ultralytics on first run. For Sam
's CoreML side, run:

```bash
python3 scripts/export_yolov8_coreml.py
```

This outputs `yolov8n.mlpackage`. Drag it into the Xcode target.

---

## Running tests

```bash
python3 -m pytest tests/ -v
```

All 17 tests pass. YOLO is mocked so no model download is needed to run tests.

---

## Open items

- [ ] Confirm wire format with Sam
 / iOS sender before first end-to-end test
- [ ] Decide on RGB resolution (1280x720 vs 1920x1080) and update depth scale math if needed
- [ ] Test actual depth map resolution from iPhone 15 Pro Max (assumed 256x192)
- [ ] Tune `confidence_threshold` and `depth_crop_ratio` on real footage
- [ ] Add a keep-alive / ping-pong to the `/haptics` WebSocket if the controller idles
