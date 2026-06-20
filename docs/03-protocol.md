# 03 — LC2 protocol

LC2 is the Lightweight Communication and Local Control protocol. It is the wire format the phone and the Coral both use to talk to the ESP32.

## Packet shape

Four bytes per packet. Connectionless UDP (default) or UART (if Coral uses Option A) or BLE (Option B). The wire is the same shape regardless of transport.

```
+--------+--------+--------+--------+
| byte 0 | byte 1 | byte 2 | byte 3 |
| event  | mask   | hint   | seq    |
+--------+--------+--------+--------+
```

| Byte | Meaning | Range |
|---|---|---|
| **0 — event** | What just happened | See event table below |
| **1 — quadrant mask** | Which servo(s) fire | Bit 0 = Far Left, bit 1 = Left, bit 2 = Right, bit 3 = Far Right |
| **2 — intensity hint** | Tap travel distance (small = subtle, large = full swing) | 0..255. Default: 192 |
| **3 — sequence number** | Rolling counter for staleness detection | 0..255, wraps |

## Event types (byte 0)

| Code | Event | Pattern | Tier | Notes |
|---|---|---|---|---|
| `0x00` | idle | none | — | Sent every heartbeat tick when nothing is staged. Keeps the link alive. |
| `0x10` | vision-danger | sustained tap-train | 3 | Coral emits when person-in-path criteria fire. |
| `0x20` | turn-slight | single tap | 2 | Phone emits for a gentle directional cue. |
| `0x21` | turn-now | triple tap | 2 | Phone emits for a sharp turn or imminent maneuver. |
| `0x22` | turn-around | triple tap on both Far servos | 2 | U-turn case. Same pattern as turn-now, different mask. |
| `0x23` | arrived | sweep left-to-right | 2 | Phone emits at the final maneuver. Also reused for calibration confirmation per [`04-phone-side.md`](04-phone-side.md). |
| `0x30` | reserved | — | — | Was vision-context in an earlier plan. Do not reuse. |
| `0x40` | obstacle-near (provisional) | sustained tap-train | 1 | Phone emits from its LiDAR scene-depth read when something is closer than the threshold straight ahead. Reuses the sustained tap-train pattern, so it stays inside the four-pattern cap. See the obstacle tier note below. |

Other byte 0 values are undefined. ESP32 should ignore unknown codes silently and log a counter.

## Obstacle tier (phone LiDAR, provisional)

`0x40 obstacle-near` revives the Tier-1 obstacle reflex that `01-architecture.md` deferred for lack of a ToF sensor. The iPhone 15 Pro Max has a LiDAR scanner, so the phone is the ToF sensor. `DepthService` samples the center of the scene-depth map and the phone emits `0x40` when the nearest reading is inside `thresholdMeters` (default 1.2 m), masked to center mass (`0x06`).

Because the phone now sends both Tier-1 and Tier-2 on the same channel, it deconflicts locally before it stages: an active obstacle cue takes priority over a route cue for that heartbeat. The wearer feels the obstacle, not the turn, while something is close. Coral's Tier-3 `vision-danger` is still a separate sender and the ESP32 deconfliction rule below is unchanged.

**This whole tier is provisional and changeable at any time.** The code, the threshold, the mask, the priority, even whether it ships at all are open. It is wired now so the team can feel it on the bench and decide. Nothing here is locked, and changing it does not need a ceremony, just an edit and a note to whoever owns the ESP32 firmware.

## Quadrant mask examples (byte 1)

| Mask | Binary | Meaning |
|---|---|---|
| `0x00` | `0000` | No servo fires. Valid for `0x00` idle. Invalid for any cue event. |
| `0x01` | `0001` | Far Left only |
| `0x02` | `0010` | Left only |
| `0x04` | `0100` | Right only |
| `0x08` | `1000` | Far Right only |
| `0x06` | `0110` | Left + Right (center mass) |
| `0x09` | `1001` | Far Left + Far Right (turn-around) |
| `0x0F` | `1111` | All four (sweep pattern animates them in sequence regardless of mask order) |

The ESP32 reads the mask one bit at a time and fires the corresponding servo with the pattern selected by byte 0.

## Cadence

Phone-side heartbeat: 10 Hz (every 100 ms). Every tick either emits an `0x00` idle or the most recently staged event.

Coral-side: event-driven only. Sends a packet at the moment a trigger fires, no heartbeat. The ESP32 treats Coral's silence as "no danger right now."

ESP32-side: services the heartbeat path. If no packet arrives for 500 ms, falls back to idle (servos quiet) until packets resume.

## Deconfliction

If a Tier-2 packet and a Tier-3 packet hit the ESP32 in the same heartbeat window and they want the same quadrant:

- Tier-3 wins on that quadrant only.
- Tier-2 holds the other quadrants.
- The wearer feels the vision danger on the affected side and still feels the route cue on the unaffected sides.

If two Tier-2 events arrive in the same window (the phone is misbehaving), the later sequence number wins. This should not happen in practice; the phone is the single Tier-2 sender.

## Sequence number

Byte 3 is a rolling counter. It exists so the ESP32 can detect:

- **Packet drops:** if the sequence jumps by more than 1 (and is not the wrap-around case 255 -> 0), at least one packet was lost in transit. The ESP32 should log this but not act on it; the next heartbeat will resend the staged state.
- **Stale packets:** if a UDP packet arrives out of order, the ESP32 can drop it by comparing the sequence number against the most recently seen one. With a 10 Hz heartbeat over local Wi-Fi this is rare but possible.

## What LC2 is not

- Not a streaming protocol. No partial frames, no fragmentation, no checksums beyond what UDP/UART/BLE already provide.
- Not bidirectional. The ESP32 does not send anything back to the phone or the Coral by default. The status LED is the only feedback channel from the belt.
- Not reliable. UDP can drop packets. The heartbeat is what guarantees the wearer eventually gets the right state, not per-packet reliability.

## Adding a new event

If a future feature needs a new event type, add it to the table above with an unused `0xNN` code and document the pattern. Do not change existing codes; the ESP32 firmware and the phone code both depend on the stable mapping.

The pattern vocabulary is hard-capped at 4. A new event must reuse an existing pattern (with a different mask, like turn-around does) or get a unanimous team vote to expand the vocabulary. The cap exists because the wearer cannot reliably distinguish more than four discrete tap patterns under demo conditions.
