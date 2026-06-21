"""
Unit tests for CVPipeline depth fusion.

YOLO is mocked throughout — no model download required.
All depth assertions use concrete bbox math so failures are diagnosable.

Coordinate reference for the default frame sizes used here (RGB 640x480, depth 256x192):
  scale_x = 256/640 = 0.40
  scale_y = 192/480 = 0.40

For bbox (100, 100, 300, 300) with depth_crop_ratio=0.5:
  scaled:  dx1=40  dy1=40  dx2=120  dy2=120
  pad_x = int((120-40) * 0.25) = 20
  pad_y = int((120-40) * 0.25) = 20
  crop:    cx1=60  cy1=60  cx2=100  cy2=100
"""

import numpy as np
import pytest
from unittest.mock import MagicMock, patch

from cv.detection import DepthFusedDetection
from cv.pipeline import CVPipeline

# ── Frame dimensions ──────────────────────────────────────────────────────────

RGB_W, RGB_H = 640, 480
DEPTH_W, DEPTH_H = 256, 192


# ── Helpers ───────────────────────────────────────────────────────────────────


def rgb_frame(w: int = RGB_W, h: int = RGB_H) -> np.ndarray:
    return np.zeros((h, w, 3), dtype=np.uint8)


def depth_map(fill: float = 2.5, w: int = DEPTH_W, h: int = DEPTH_H) -> np.ndarray:
    return np.full((h, w), fill, dtype=np.float32)


def mock_yolo_result(label_id: int, label: str, conf: float, x1, y1, x2, y2):
    """Build a minimal ultralytics-compatible result mock."""
    box = MagicMock()
    box.cls = np.array([float(label_id)])
    box.conf = np.array([conf])
    box.xyxy = np.array([[float(x1), float(y1), float(x2), float(y2)]])

    result = MagicMock()
    result.boxes = [box]
    result.names = {label_id: label}
    return [result]


def empty_yolo_result():
    result = MagicMock()
    result.boxes = []
    result.names = {}
    return [result]


# ── Tests ─────────────────────────────────────────────────────────────────────


class TestDepthFusion:
    @patch("cv.pipeline.YOLO")
    def test_extracts_depth_from_correct_region(self, mock_cls):
        """Median depth should match the value planted inside the crop window."""
        dm = depth_map(fill=float("nan"))
        dm[60:100, 60:100] = 3.0  # exactly the expected crop window

        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 100, 100, 300, 300)
        )

        results = CVPipeline().process(rgb_frame(), dm, timestamp_s=0.0)

        assert results[0].depth_median_m == pytest.approx(3.0)

    @patch("cv.pipeline.YOLO")
    def test_depth_min_is_closest_point(self, mock_cls):
        """depth_min_m must be the nearest valid point in the crop, not the median."""
        dm = depth_map(fill=5.0)
        dm[70, 70] = 1.2  # single close point inside crop [60:100, 60:100]

        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 100, 100, 300, 300)
        )

        results = CVPipeline().process(rgb_frame(), dm, timestamp_s=0.0)

        assert results[0].depth_min_m == pytest.approx(1.2)

    @patch("cv.pipeline.YOLO")
    def test_all_nan_depth_returns_none(self, mock_cls):
        """When the entire depth region is NaN, both depth fields must be None."""
        dm = np.full((DEPTH_H, DEPTH_W), float("nan"), dtype=np.float32)

        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 100, 100, 300, 300)
        )

        results = CVPipeline().process(rgb_frame(), dm, timestamp_s=0.0)

        assert results[0].depth_median_m is None
        assert results[0].depth_min_m is None

    @patch("cv.pipeline.YOLO")
    def test_zero_depth_treated_as_missing(self, mock_cls):
        """Zero depth is a no-return sentinel on iPhone LiDAR, not a real distance."""
        dm = np.zeros((DEPTH_H, DEPTH_W), dtype=np.float32)

        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 100, 100, 300, 300)
        )

        results = CVPipeline().process(rgb_frame(), dm, timestamp_s=0.0)

        assert results[0].depth_median_m is None


class TestHorizontalNorm:
    @patch("cv.pipeline.YOLO")
    def test_center_bbox_gives_half(self, mock_cls):
        # bbox center x = (200+440)/2 = 320; rgb_w = 640 → norm = 0.5
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 200, 100, 440, 300)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert results[0].horizontal_norm == pytest.approx(0.5)

    @patch("cv.pipeline.YOLO")
    def test_left_bbox_below_half(self, mock_cls):
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 0, 0, 100, 100)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert results[0].horizontal_norm < 0.5

    @patch("cv.pipeline.YOLO")
    def test_right_bbox_above_half(self, mock_cls):
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 540, 0, 640, 100)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert results[0].horizontal_norm > 0.5


class TestClassFilter:
    @patch("cv.pipeline.YOLO")
    def test_non_navigation_class_dropped(self, mock_cls):
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(74, "clock", 0.99, 100, 100, 200, 200)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert results == []

    @patch("cv.pipeline.YOLO")
    def test_navigation_class_kept(self, mock_cls):
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.9, 100, 100, 200, 200)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert len(results) == 1
        assert results[0].label == "person"

    @patch("cv.pipeline.YOLO")
    def test_empty_frame_returns_empty_list(self, mock_cls):
        mock_cls.return_value = MagicMock(return_value=empty_yolo_result())
        results = CVPipeline().process(rgb_frame(), depth_map(), timestamp_s=0.0)
        assert results == []


class TestOutputShape:
    @patch("cv.pipeline.YOLO")
    def test_returns_depth_fused_detection_instances(self, mock_cls):
        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "person", 0.88, 50, 50, 200, 200)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(fill=2.0), timestamp_s=1234.5)

        d = results[0]
        assert isinstance(d, DepthFusedDetection)
        assert d.label == "person"
        assert d.confidence == pytest.approx(0.88)
        assert d.bbox_px == (50, 50, 200, 200)
        assert d.timestamp_s == pytest.approx(1234.5)

    @patch("cv.pipeline.YOLO")
    def test_to_dict_is_json_serializable(self, mock_cls):
        import json

        mock_cls.return_value = MagicMock(
            return_value=mock_yolo_result(0, "car", 0.75, 10, 10, 400, 300)
        )
        results = CVPipeline().process(rgb_frame(), depth_map(fill=3.0), timestamp_s=0.0)
        serialized = json.dumps(results[0].to_dict())
        assert "car" in serialized
