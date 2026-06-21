"""
WebSocket frame ingestion layer.

The iPhone app streams paired frames as binary WebSocket messages.
Wire format (each message):
    [8 bytes]  float64 unix timestamp
    [4 bytes]  uint32  JPEG byte length  (N)
    [N bytes]  JPEG-encoded RGB frame
    [4 bytes]  uint32  depth map rows    (H)
    [4 bytes]  uint32  depth map cols    (W)
    [H*W*4 bytes] float32 depth map, row-major, meters, NaN for no-return

Adjust the format to match whatever the iOS side actually sends.
"""

import asyncio
import struct
import time

import cv2
import numpy as np
from fastapi import FastAPI, WebSocket

from .pipeline import CVPipeline

app = FastAPI()
pipeline = CVPipeline()

# Downstream consumers register here (e.g. haptic WebSocket output, MQTT publisher).
# Each callback receives a list[DepthFusedDetection].
_output_callbacks: list = []


def register_output(callback) -> None:
    _output_callbacks.append(callback)


def _parse_frame(data: bytes) -> tuple[np.ndarray, np.ndarray, float]:
    """Unpack binary message into (rgb_frame, depth_map, timestamp)."""
    offset = 0

    timestamp_s = struct.unpack_from("d", data, offset)[0]
    offset += 8

    jpeg_len = struct.unpack_from("I", data, offset)[0]
    offset += 4

    jpeg_bytes = data[offset : offset + jpeg_len]
    offset += jpeg_len

    rows, cols = struct.unpack_from("II", data, offset)
    offset += 8

    depth_flat = np.frombuffer(data[offset : offset + rows * cols * 4], dtype=np.float32)
    depth_map = depth_flat.reshape((rows, cols))

    rgb_frame = cv2.imdecode(np.frombuffer(jpeg_bytes, np.uint8), cv2.IMREAD_COLOR)

    return rgb_frame, depth_map, timestamp_s


@app.websocket("/frames")
async def frames_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    loop = asyncio.get_event_loop()

    try:
        while True:
            raw = await ws.receive_bytes()

            # Run inference on thread pool so the WebSocket event loop stays free.
            detections = await loop.run_in_executor(None, _process, raw)

            for cb in _output_callbacks:
                await cb(detections)

    except Exception:
        pass
    finally:
        await ws.close()


def _process(raw: bytes):
    rgb_frame, depth_map, timestamp_s = _parse_frame(raw)
    return pipeline.process(rgb_frame, depth_map, timestamp_s)
