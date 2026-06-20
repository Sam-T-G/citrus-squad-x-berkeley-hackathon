# 04 — Phone side

The phone is the brain of Tier-2. It reads Google Maps directions, tracks the wearer's GPS, reads its own compass for body heading, and emits LC2 packets to the ESP32 that say which way to tap.

## What the phone owns

- Google Maps Directions API call at route start; cached for the whole route.
- GPS polled at 1 Hz.
- True heading from the OS-fused compass (magnetometer + gyro + accel) at 1 Hz minimum.
- Optional accelerometer + gyro at 50 Hz for bonus features (fall detection, step counting between GPS fixes).
- Body-relative bearing computation for every maneuver.
- LC2 packet staging and 10 Hz heartbeat emission.
- LiDAR proximity sensing, and camera person-in-path as a stretch. These are the safety tier, designed in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md). This doc covers the direction tier.

## What the phone does NOT own

- Driving servos. The ESP32 does that.
- Knowing about the belt's hardware state. The phone only knows what packets it has emitted.

## The heading math

The phone's compass reports where the phone is pointed in true-north degrees, 0 to 360. Because the phone is rigidly chest-mounted facing forward, after a one-time calibration offset, phone heading equals body heading.

```
body_heading = (phone_true_heading - calibration_offset + 360) % 360
```

Google Maps gives the route bearing of each maneuver point in true-north degrees. The relative bearing the wearer needs to turn through is:

```
body_relative_bearing = (route_bearing - body_heading + 360) % 360
```

A value of 0° means "the turn is straight ahead." 90° means "turn 90° right." 270° (= -90°) means "turn 90° left." 180° means "turn around."

This relative bearing maps to one of four belt quadrants, which sets the LC2 quadrant mask byte.

## Quadrant mapping

| Body-relative bearing | Quadrant | Pattern (default) |
|---|---|---|
| 350° to 10° (centerline forward) | none | no tap |
| 10° to 60° | Right | single tap (slight) |
| 60° to 120° | Far Right | triple tap (sharp) |
| 120° to 240° | both Far servos | triple tap (turn-around) |
| 240° to 300° | Far Left | triple tap (sharp) |
| 300° to 350° | Left | single tap (slight) |

Hysteresis on the quadrant boundaries: ±5° for adjacent transitions (Right ↔ Far Right), ±10° for the turn-around case. Prevents flicker when the wearer's heading hovers near a boundary.

## Calibration

Calibration captures the offset between phone-forward and body-forward at the start of the route. The wearer stands still, faces the way they want "forward" to mean, and the operator taps a button. The system records `offset = current_phone_heading` and uses that for the rest of the route.

### How calibration is triggered

Two options, default is the first:

1. **Phone screen button (default).** Large labeled button on the main screen. Operator taps it before the wearer starts walking.
2. **Belt push-button (stretch).** The wearer presses a button on the belt. Adds a reverse-direction LC2 channel from ESP32 to phone that does not exist in the base protocol. Cost: 1-2 hours of extra work. Ship phone button at M2; add belt button only after M5 if time allows.

### Calibration confirmation

The wearer needs to know calibration worked without looking at the phone. Default: chime + screen flash. If the chime is unreliable in the venue (loud), fall back to a brief test sweep on the belt (reuses the existing `0x23 arrived` pattern, runs at lower intensity).

The wearer cannot confuse a calibration sweep with an arrived sweep because calibration always happens before the route starts and arrived always happens at the route's final maneuver point.

### When to recalibrate

The offset can drift if:

- The harness moves on the wearer's body (loose strap, walking jostle).
- The OS reports low magnetometer confidence (interference, hardware degradation).
- The wearer manually adjusts the phone position.

Default recalibration triggers:

| Trigger | Action |
|---|---|
| OS magnetometer confidence flag stays low for two consecutive samples | UI banner "Recalibrate before next turn." Soft invalidate. Next turn cue is suppressed until calibration runs. |
| Operator notices the compass sticking or rotating opposite to phone motion | Hard invalidate. Banner "Not calibrated." Route paused. |
| The wearer stops at a stoplight for ≥10 seconds (held-still detection) | Optional auto-recalibration. Bonus feature; defer until base layer ships. |

## Maps integration

One Directions API call at route start. Cache every step. The local Maps SDK does this for you on both iOS and Android.

GPS poll at 1 Hz. Compute haversine distance to the next maneuver point. When distance crosses a "turn commit" threshold (about 5 meters before the maneuver), stage an event packet for the next heartbeat to send.

Reroute only on a deviation of more than 25 m from the cached polyline. Random GPS noise of a few meters should not trigger a re-route.

If GPS drops entirely, the heartbeat keeps sending idle. The wearer feels nothing rather than feeling a stale cue. The UI shows a "no GPS" indicator so the operator knows.

## Sensor permissions

The app needs three iOS permission keys (or the Android equivalent):

| Key | Reason |
|---|---|
| Location (when in use) | GPS for navigation, heading from CoreLocation |
| Motion + fitness | Accelerometer and gyro for the optional 50 Hz bonus features |
| Camera | Only if the phone runs any vision work in a later version. Not used for Tier-2. |

Free-tier Apple Developer signing covers a 7-day cert window, which is enough for the hackathon. Re-install if the demo phone is still in use after that.

## Milestones

These are the gates that determine whether Tier-2 ships.

| Milestone | What lands | Quality gate |
|---|---|---|
| **M0** | App compiles. Sends one UDP packet that the ESP32 receives. | "Hello packet" arrives within 100 ms. |
| **M1** | Heading service smooths and applies calibration offset. | Body heading reads ±10° while the phone is held still. |
| **M2** | Calibration button records offset; two consecutive presses produce matching offsets. | Offsets within 2°. |
| **M3** | GPS + Maps polyline cached. Body-relative bearing math correct on paper data. | Bearing matches a hand-computed sample to within 1°. |
| **M4** | Quadrant mapper picks the right servo for synthetic test inputs. | All eight cardinal directions pass. |
| **M5** | Full route playback. Walk the 30 m demo loop, all turn cues fire on the correct side. | Three consecutive clean walks. |
| **M6 (optional)** | Bonus: step counting between GPS fixes, fall detection, auto-recalibration on held-still. | Bonus criterion: any one of these working. |

M5 is the line for "shippable in the demo." M6 is the line for "we have time left and want to differentiate."

## Stack note

Native iOS (Swift + SwiftUI) is the proven-viable path on the demo phone; capabilities verified in [`10-validated.md`](10-validated.md). Expo (React Native + TypeScript) is a possible alternative that adds a sensor-access bridge layer. The choice happens at the alignment meeting.

If the choice is native iOS:

- `CLLocationManager` covers heading + GPS in one delegate.
- `CMMotionManager` covers accel + gyro at any rate up to 100 Hz.
- `AVCaptureSession` covers camera (not used for Tier-2, but verified working).

If the choice is Expo:

- `expo-location` covers GPS, heading via a bridge.
- `expo-sensors` covers accelerometer + gyroscope.
- Bridge latency is a few ms per read; should still fit the 1 Hz Tier-2 cadence comfortably. Watch for it on the 50 Hz bonus path.
