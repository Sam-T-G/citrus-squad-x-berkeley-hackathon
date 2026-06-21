"""
Webcam smoke test for CVPipeline.

No LiDAR available on a laptop, so we inject a flat 2.0 m depth map
the same size as the RGB frame.  Depth values in detections will all
read ~2.0 m -- the important thing is that detection and class filtering
work end-to-end.

Usage:
    python -m cv.webcam_test          # default camera (index 0)
    python -m cv.webcam_test 1        # external camera index 1

Keybinds while running:
    q  --  quit
"""

from __future__ import annotations

import sys
import time

import cv2
import numpy as np

from .pipeline import CVPipeline

SYNTHETIC_DEPTH_M = 2.0
FONT = cv2.FONT_HERSHEY_SIMPLEX


def _color_for_label(label: str) -> tuple[int, int, int]:
    h = hash(label) % 360
    # Convert hue to BGR via a small lookup so boxes don't all look the same.
    rgb = cv2.cvtColor(
        np.uint8([[[h, 200, 200]]]), cv2.COLOR_HSV2BGR
    )[0][0]
    return int(rgb[0]), int(rgb[1]), int(rgb[2])


def run(camera_index: int = 0) -> None:
    pipeline = CVPipeline()

    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open camera {camera_index}")

    print(f"Camera {camera_index} opened. Press 'q' to quit.")

    fps_t = time.time()
    frame_count = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            print("Frame grab failed -- exiting.")
            break

        h, w = frame.shape[:2]
        depth_map = np.full((h, w), SYNTHETIC_DEPTH_M, dtype=np.float32)

        detections = pipeline.process(frame, depth_map)

        for det in detections:
            x1, y1, x2, y2 = det.bbox_px
            color = _color_for_label(det.label)
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)

            depth_str = (
                f"{det.depth_median_m:.1f}m" if det.depth_median_m is not None else "?m"
            )
            text = f"{det.label} {det.confidence:.2f} | {depth_str} | h={det.horizontal_norm:.2f}"
            cv2.putText(frame, text, (x1, max(y1 - 6, 14)), FONT, 0.5, color, 1, cv2.LINE_AA)

            print(det.to_dict())

        frame_count += 1
        elapsed = time.time() - fps_t
        if elapsed >= 1.0:
            fps = frame_count / elapsed
            frame_count = 0
            fps_t = time.time()
            cv2.putText(
                frame, f"FPS: {fps:.1f}", (8, 20), FONT, 0.6, (0, 255, 0), 1, cv2.LINE_AA
            )

        cv2.imshow("CVPipeline -- webcam test (q to quit)", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    run(idx)
