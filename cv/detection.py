from __future__ import annotations

from dataclasses import asdict, dataclass

# COCO classes relevant to pedestrian navigation.
# YOLOv8n sees all 80 classes; we filter to these after inference.
NAVIGATION_CLASSES: frozenset[str] = frozenset(
    {
        "person",
        "bicycle",
        "car",
        "motorcycle",
        "bus",
        "truck",
        "chair",
        "couch",
        "dining table",
        "bed",
        "stop sign",
        "traffic light",
        "fire hydrant",
        "parking meter",
        "bench",
        "potted plant",
        "dog",
        "cat",
        "backpack",
        "suitcase",
        "umbrella",
    }
)


@dataclass
class DepthFusedDetection:
    label: str
    confidence: float

    # Bounding box in RGB pixel space: (x1, y1, x2, y2)
    bbox_px: tuple[int, int, int, int]

    # Depth in meters sampled from the LiDAR map at this bbox.
    # None if the depth region was all NaN / out of range.
    depth_median_m: float | None
    depth_min_m: float | None  # closest point in bbox — most safety-relevant

    # Normalized horizontal center [0.0 = full left, 1.0 = full right].
    # Downstream haptic layer uses this to pick belt zone without knowing frame size.
    horizontal_norm: float

    # Unix timestamp matching the source frame pair.
    timestamp_s: float

    def to_dict(self) -> dict:
        return asdict(self)
