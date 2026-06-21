# CV Log Sessions

Raw pipeline output from `ObjectDetectionService` + `MotionTracker`. One CSV per session.
Use these to tune thresholds in `MotionParameters.swift` without needing to re-run on the phone.

## How to add a log

1. On the phone: diagnostics console → Object detection card → Start log → walk the scenario → Stop log
2. Open Files → On My iPhone → CitrusSquad → CVLogs → copy the CSV to this folder
3. Commit it

## CSV columns

| Column | Description |
|---|---|
| `timestamp_ms` | Milliseconds since session start |
| `frame` | Detection pipeline frame index (~5 Hz) |
| `label` | YOLO class label (person, bicycle, car, …) |
| `confidence` | YOLO confidence score (0–1) |
| `h_norm` | Horizontal position in portrait frame (0 = left, 1 = right) |
| `dist_m` | LiDAR-fused distance in meters (-1 = no reading) |
| `approach_mps` | Approach rate m/s — positive = closing, negative = receding |
| `lateral_nps` | Lateral rate norm/s — positive = moving right |
| `motion_state` | MotionTracker output: unknown / stationary / moving / approaching / receding |
| `frames_tracked` | Consecutive frames this object identity has been matched |
| `band_left` | LiDAR left-band depth at this frame (m) |
| `band_center` | LiDAR center-band depth (m) |
| `band_right` | LiDAR right-band depth (m) |

Empty `label` rows are no-detection sentinels — YOLO ran but found nothing that frame.

## Thresholds to tune (MotionParameters.swift)

- `approachThresholdMetersPerSecond` (0.15) — raise if stationary people are being classified as approaching
- `lateralThresholdNormPerSecond` (0.04) — raise if objects standing still show up as moving
- `settleFrames` (3) — raise if single-frame detections are triggering belt cues
- `matchRadiusNorm` (0.15) — raise if the same person is losing and re-acquiring their track while walking

## Sessions
