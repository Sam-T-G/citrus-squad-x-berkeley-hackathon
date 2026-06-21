"""
Tests for the binary frame ingestion protocol.

Verifies that _parse_frame correctly unpacks the wire format produced
by the iPhone sender, including JPEG decode and float32 depth roundtrip.
"""

import struct

import cv2
import numpy as np
import pytest

from cv.ingest import _parse_frame


def encode_frame(timestamp: float, rgb: np.ndarray, depth: np.ndarray) -> bytes:
    """Produce a wire-format message matching the protocol in ingest.py."""
    jpeg = cv2.imencode(".jpg", rgb, [cv2.IMWRITE_JPEG_QUALITY, 95])[1].tobytes()
    rows, cols = depth.shape
    return (
        struct.pack("d", timestamp)
        + struct.pack("I", len(jpeg))
        + jpeg
        + struct.pack("II", rows, cols)
        + depth.astype(np.float32).tobytes()
    )


class TestParseFrame:
    def test_timestamp_roundtrip(self):
        ts = 1_718_000_000.123
        rgb = np.zeros((480, 640, 3), dtype=np.uint8)
        depth = np.ones((192, 256), dtype=np.float32)
        _, _, parsed_ts = _parse_frame(encode_frame(ts, rgb, depth))
        assert parsed_ts == pytest.approx(ts)

    def test_depth_shape(self):
        rgb = np.zeros((480, 640, 3), dtype=np.uint8)
        depth = np.ones((192, 256), dtype=np.float32)
        _, parsed_depth, _ = _parse_frame(encode_frame(0.0, rgb, depth))
        assert parsed_depth.shape == (192, 256)

    def test_depth_values_roundtrip(self):
        """Raw float32 depth should survive the encode/decode cycle exactly."""
        rgb = np.zeros((480, 640, 3), dtype=np.uint8)
        depth = np.random.rand(192, 256).astype(np.float32) * 10.0
        _, parsed_depth, _ = _parse_frame(encode_frame(0.0, rgb, depth))
        np.testing.assert_array_equal(parsed_depth, depth)

    def test_rgb_shape(self):
        rgb = np.zeros((720, 1280, 3), dtype=np.uint8)
        depth = np.ones((192, 256), dtype=np.float32)
        parsed_rgb, _, _ = _parse_frame(encode_frame(0.0, rgb, depth))
        assert parsed_rgb.shape == (720, 1280, 3)

    def test_nan_depth_preserved(self):
        """NaN entries in the depth map must survive the binary roundtrip."""
        rgb = np.zeros((480, 640, 3), dtype=np.uint8)
        depth = np.full((192, 256), float("nan"), dtype=np.float32)
        _, parsed_depth, _ = _parse_frame(encode_frame(0.0, rgb, depth))
        assert np.all(np.isnan(parsed_depth))
