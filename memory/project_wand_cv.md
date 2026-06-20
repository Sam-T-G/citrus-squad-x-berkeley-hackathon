---
name: project-wand-cv
description: Python CV pipeline status for WAND haptic belt — what's built, who owns what, open items
metadata:
  type: project
---

CV layer is built and tested (17/17 passing). It lives in `cv/` and `server.py`.

Cole owns: `cv/`, `server.py`, `tests/`, `scripts/export_yolov8_coreml.py`
Josh owns: iOS app, LiDAR streaming, Swift haptic controller

**Why:** WAND is a haptic navigation belt for blind/low-vision wearers. iPhone 15 Pro Max streams RGB + LiDAR depth over local WebSocket to a Python server. YOLOv8n detects obstacles; pipeline fuses detections with LiDAR depth; JSON results broadcast to haptic controller.

**How to apply:** When adding features to the CV layer, keep the pipeline transport-agnostic (`CVPipeline.process` takes numpy arrays). The integration seam with Josh is the `/haptics` WebSocket JSON format defined in `HANDOFF.md`.

Open items (as of 2026-06-20):
- Wire format confirmation with Josh / iOS sender
- RGB resolution decision (affects depth scale math)
- Actual LiDAR depth map resolution from iPhone 15 Pro Max (assumed 256x192)
- Confidence threshold + crop ratio tuning on real footage
