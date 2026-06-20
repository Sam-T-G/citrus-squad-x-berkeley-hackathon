from __future__ import annotations

import time

import numpy as np
from ultralytics import YOLO

from .detection import NAVIGATION_CLASSES, DepthFusedDetection


class CVPipeline:
    """
    Transport-agnostic CV layer.

    Caller provides a matched (rgb_frame, depth_map) pair as numpy arrays
    and gets back a list of DepthFusedDetection objects ready to ship
    downstream over whatever transport the haptic layer expects.

    rgb_frame  : (H, W, 3) uint8, BGR (OpenCV default) or RGB — YOLO handles both
    depth_map  : (Hd, Wd) float32, depth in meters, NaN where LiDAR had no return
    """

    def __init__(
        self,
        model_path: str = "yolov8n.pt",
        conf_threshold: float = 0.35,
        # Inner fraction of each bbox used for depth sampling.
        # 0.5 = center 50%, avoiding noisy bounding-box edges where LiDAR
        # returns may bleed across the object boundary.
        depth_crop_ratio: float = 0.5,
    ) -> None:
        self.model = YOLO(model_path)
        self.conf_threshold = conf_threshold
        self.depth_crop_ratio = depth_crop_ratio

    # ------------------------------------------------------------------
    # Public
    # ------------------------------------------------------------------

    def process(
        self,
        rgb_frame: np.ndarray,
        depth_map: np.ndarray,
        timestamp_s: float | None = None,
    ) -> list[DepthFusedDetection]:
        if timestamp_s is None:
            timestamp_s = time.time()

        raw = self._detect(rgb_frame)
        return [self._fuse(d, depth_map, rgb_frame.shape, timestamp_s) for d in raw]

    # ------------------------------------------------------------------
    # Private
    # ------------------------------------------------------------------

    def _detect(self, frame: np.ndarray) -> list[dict]:
        results = self.model(frame, conf=self.conf_threshold, verbose=False)[0]
        detections = []
        for box in results.boxes:
            label = results.names[int(box.cls[0])]
            if label not in NAVIGATION_CLASSES:
                continue
            x1, y1, x2, y2 = (int(v) for v in box.xyxy[0].tolist())
            detections.append(
                {
                    "label": label,
                    "confidence": float(box.conf[0]),
                    "bbox": (x1, y1, x2, y2),
                }
            )
        return detections

    def _fuse(
        self,
        detection: dict,
        depth_map: np.ndarray,
        rgb_shape: tuple,
        timestamp_s: float,
    ) -> DepthFusedDetection:
        rgb_h, rgb_w = rgb_shape[:2]
        depth_h, depth_w = depth_map.shape[:2]

        x1, y1, x2, y2 = detection["bbox"]

        # Scale bbox from RGB resolution to depth map resolution.
        # iPhone LiDAR depth maps are typically 256x192; RGB is 1280x720 or higher.
        sx = depth_w / rgb_w
        sy = depth_h / rgb_h
        dx1, dy1 = int(x1 * sx), int(y1 * sy)
        dx2, dy2 = int(x2 * sx), int(y2 * sy)

        # Shrink to inner crop to reduce edge bleed noise.
        r = self.depth_crop_ratio
        pad_x = int((dx2 - dx1) * (1 - r) / 2)
        pad_y = int((dy2 - dy1) * (1 - r) / 2)
        cx1 = max(0, dx1 + pad_x)
        cy1 = max(0, dy1 + pad_y)
        cx2 = min(depth_w, dx2 - pad_x)
        cy2 = min(depth_h, dy2 - pad_y)

        region = depth_map[cy1:cy2, cx1:cx2]

        # Drop NaN, inf, and zero (zero = no LiDAR return on iPhone).
        valid = region[np.isfinite(region) & (region > 0.0)]

        depth_median = float(np.median(valid)) if valid.size > 0 else None
        depth_min = float(np.min(valid)) if valid.size > 0 else None

        horizontal_norm = ((x1 + x2) / 2.0) / rgb_w

        return DepthFusedDetection(
            label=detection["label"],
            confidence=detection["confidence"],
            bbox_px=detection["bbox"],
            depth_median_m=depth_median,
            depth_min_m=depth_min,
            horizontal_norm=horizontal_norm,
            timestamp_s=timestamp_s,
        )
