# 01 — Architecture

## Three tiers, one belt

WAND has two base tiers and one conditional tier. All three share the same four servos. Patterns differentiate which tier the wearer is feeling.

| Tier | Purpose | Signal source | Status |
|---|---|---|---|
| **Tier-2 Direction** | "Turn left," "turn right," "you've arrived" | Phone (Maps + compass) | Primary base layer |
| **Tier-3 Vision safety** | "Someone is walking into your path" | Coral Dev Board on the belt | Conditional; cuts if Coral bring-up slips |
| **Tier-1 Obstacle reflex** | "Something is right in front of you" | ToF sensors | Deferred (parts not in inventory; pitch discloses gap) |

Tier-1 is deferred only because we do not have ToF sensors on hand. The architecture leaves room for it to return in a future build.

## System diagram

```
+-----------------------------+         +-----------------------------+
|        DEMO PHONE           |         |        CORAL DEV BOARD      |
|  (chest-mounted, forward)   |         |  (belt-mounted, fwd camera) |
|                             |         |                             |
|  Google Maps Directions     |         |  MobileNet-SSD over Edge TPU|
|  GPS @ 1 Hz                 |         |  Trigger filter (person +   |
|  CoreLocation true heading  |         |   box height + debounce)    |
|  CoreMotion accel + gyro    |         |                             |
+--------------+--------------+         +--------------+--------------+
               |                                       |
               | UDP packet (LC2)                      | UDP / UART / BLE (LC2)
               | over Wi-Fi or hotspot                 | choice in §04 below
               v                                       v
+-----------------------------------------------------------------------+
|                              ESP32                                    |
|  (belt-mounted, 3.3 V logic, drives servos via GPIO PWM)              |
|                                                                       |
|  Heartbeat loop @ 10 Hz reads incoming packets                        |
|  Deconflict: Tier-3 wins on affected quadrant; Tier-2 holds the rest  |
|  Outputs PWM to four servos at 50 Hz update rate                      |
+--------+--------+--------+--------+-----------------------------------+
         |        |        |        |
         v        v        v        v
   +-----+--+ +---+--+ +---+--+ +---+----+
   | Far Lf | | Left | | Right| | Far Rt |
   +--------+ +------+ +------+ +--------+
       four hobby servos (tap actuators on chest/torso)
```

## Tier-2 data flow (the critical path)

This is the path the demo relies on. If anything here fails, the demo dies.

```
[Phone] One Directions API call at route start
  -> [Phone] cache all maneuver points
  -> [Phone] every 1 second:
       read GPS
       read CoreLocation true heading
       compute body-relative bearing to next maneuver
       if approaching a turn:
         pick quadrant mask from bearing
         stage LC2 packet (event = turn-slight or turn-now or turn-around)
  -> [Phone] every 100 ms heartbeat:
       emit staged packet, or 0x00 idle if none pending
  -> [ESP32] receive packet, parse event + mask + intensity
  -> [ESP32] drive matching servos with the pattern for that event
  -> [Wearer] feels the tap on the correct side
```

End-to-end target latency from packet emit to felt tap: under 250 ms. Comfortable for a navigation cue (this is not a reflex signal; the wearer has time to react).

## Tier-3 data flow (conditional)

```
[Coral] camera frame at 10-30 Hz
  -> [Coral] TFLite inference on Edge TPU
  -> [Coral] trigger filter (person class + box height + debounce + rate limit)
  -> [Coral] if triggered: emit LC2 packet (0x10 vision-danger + quadrant mask)
  -> [ESP32] receive, deconflict against Tier-2, drive sustained tap-train
  -> [Wearer] feels rapid taps on the affected quadrant
```

Coral does not know about routes, headings, or wearer state. It only knows "what is in front of me." The phone owns "where to go." The ESP32 owns "translate events into physical taps."

## Why the phone, the ESP32, and Coral are all separate

The split is deliberate. Each device does what it is uniquely good at:

- **Phone** is the only thing with GPS, magnetometer, and the cellular link to Google Maps.
- **ESP32** is the only thing that can drive four PWM channels at a deterministic rate without being interrupted by a garbage collector or an OS scheduler.
- **Coral** is the only thing with a Tensor Processing Unit that runs inference at >10 FPS on battery power without thermal throttling.

Merging two of them (e.g. running CV on the phone or running the servos from the Coral) would either tank one of those properties or add a translation layer that does not exist today.

## Failure tolerance

- If the phone link drops, the ESP32 stops getting Tier-2 packets and falls back to idle (servos quiet) after 500 ms of silence. No false cues fire.
- If the Coral link drops, Tier-2 keeps working. The demo still ships, with the safety story disclosed in the pitch.
- If both links drop, the wearer feels nothing. This is the right behavior. Feeling nothing is better than feeling a stale cue.
- If the ESP32 reboots, the heartbeat re-establishes and operation resumes. The 100 ms heartbeat cadence makes recovery invisible.
