---
name: project-wand-cv
description: Python CV pipeline status for Citrus Squad haptic belt — what's built, who owns what, open items
metadata:
  type: project
---

CV layer is built and tested (17/17 passing). Lives in `cv/` and `server.py` on `cole/computer-vision` branch, rebased onto main.

Cole owns: `cv/`, `server.py`, `tests/`, collision prediction logic (Python), CoreML model export
Sam owns: iOS app, LiDAR, `ObjectDetectionService.swift` (CoreML iOS integration), ESP32
Josh owns: audio (`AudioCueSink`)

**Why:** Citrus Squad is a haptic navigation belt for blind/low-vision wearers. The CV layer identifies objects in the path (pole, person, car) and feeds collision predictions into the same arbitration loop that drives the belt. The Python server is the working prototype; on-device CoreML is the demo target.

**How to apply:** Cole's deliverables are Python only. The integration seam with Sam is the `/haptics` WebSocket JSON format and the `VisionHazardSource.report()` / `clear()` contract defined in `HANDOFF.md`. Cole specifies the data contract; Sam wires it into Swift.

Open items (as of 2026-06-20):
- Implement `CollisionPredictor` in Python (NavigationAction: StepLeft/StepRight/Stop/SlowDown)
- Export `yolov8n.mlpackage` for Sam's CoreML integration
- Confirm ARFrame depth map resolution on iPhone 15 Pro Max (assumed 256x192)
- Confirm wire format with Sam before first end-to-end test
- Tune confidence threshold + crop ratio on real footage
