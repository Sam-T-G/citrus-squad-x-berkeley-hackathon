"""Stand-in for the phone. Sends a scripted LC2 cue stream over the WebSocket at
10 Hz so the server -> serial -> belt path can be tested before the iOS app is wired.

Usage:
  python test_client.py                 # localhost
  python test_client.py 192.168.1.50    # a laptop on the network
"""

import asyncio
import sys

import websockets

# Each step is (event, mask, label), held for a number of 100 ms ticks. Masks use the
# cardinal layout (front 0x01, left 0x02, right 0x04) so the run exercises l / r / f / s
# on belt.ino. The server collapses each held cue to a single command byte (change-only).
SCRIPT = [
    (0x00, 0x00, "idle", 10),
    (0x21, 0x02, "turn-now Left", 6),
    (0x00, 0x00, "idle", 6),
    (0x21, 0x04, "turn-now Right", 6),
    (0x00, 0x00, "idle", 6),
    (0x20, 0x01, "straight", 6),
    (0x00, 0x00, "idle", 6),
    (0x10, 0x06, "hazard center", 10),
    (0x00, 0x00, "idle", 10),
]


async def main(host: str) -> None:
    uri = f"ws://{host}:8080/belt"
    print(f"connecting to {uri}")
    async with websockets.connect(uri) as ws:
        print("connected; streaming at 10 Hz (Ctrl-C to stop)")
        seq = 0
        while True:
            for event, mask, label, ticks in SCRIPT:
                print(f"  {label}")
                for _ in range(ticks):
                    intensity = 192
                    await ws.send(bytes([event, mask, intensity, seq & 0xFF]))
                    seq += 1
                    await asyncio.sleep(0.1)  # 10 Hz heartbeat


if __name__ == "__main__":
    host = sys.argv[1] if len(sys.argv) > 1 else "localhost"
    try:
        asyncio.run(main(host))
    except KeyboardInterrupt:
        print("\nstopped")
