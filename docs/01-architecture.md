# 01 — Architecture

## Three tiers, one belt

The phone owns all the sensing now. Direction and proximity safety are both base layers, person-in-path is a stretch, and all three share the same four servos. Patterns differentiate which tier the wearer is feeling. The full perception design lives in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md).

| Tier | Purpose | Signal source | Status |
|---|---|---|---|
| **Direction** | "Turn left," "turn right," "you've arrived" | Phone (Maps + compass) | Primary base layer |
| **Proximity safety** | "Something is close ahead, on this side" | Phone LiDAR (scene depth) | Base layer |
| **Person-in-path** | "A person is moving into your path" | Phone camera (Vision) | Stretch on top of proximity |

The iPhone 15 Pro Max carries a LiDAR scanner and a camera, so the phone is the sensor. That revived the obstacle reflex the old plan had deferred for lack of a ToF part, and it dropped the device count from three to two: the phone is sensing plus brain, the ESP32 is the actuator. The Coral Dev Board, which an earlier plan used for the vision tier, is now an optional sponsor-angle stretch only. The base demo does not depend on it. See [`05-vision-tier.md`](05-vision-tier.md).

## System diagram

```
+-----------------------------------------+
|              DEMO PHONE                  |
|        (chest-mounted, forward)         |
|                                         |
|  Google Maps Directions                 |
|  GPS @ 1 Hz                            |
|  CoreLocation true heading              |
|  CoreMotion accel + gyro                |
|  LiDAR scene depth (proximity)          |
|  Camera + Vision (person-in-path, stch) |
|                                         |
|  Arbitrate: hazard preempts direction   |
+--------------------+--------------------+
                     |
                     | one UDP packet (LC2) per heartbeat
                     | over Wi-Fi or hotspot
                     v
+-----------------------------------------------------------------------+
|                              ESP32                                    |
|  (belt-mounted, 3.3 V logic, drives servos via GPIO PWM)              |
|                                                                       |
|  Heartbeat loop @ 10 Hz reads incoming packets                        |
|  Renders the event the phone sent; falls back to quiet on silence     |
|  Outputs PWM to four servos at 50 Hz update rate                      |
+--------+--------+--------+--------+-----------------------------------+
         |        |        |        |
         v        v        v        v
   +-----+--+ +---+--+ +---+--+ +---+----+
   | Far Lf | | Left | | Right| | Far Rt |
   +--------+ +------+ +------+ +--------+
       four hobby servos (tap actuators on chest/torso)
```

The phone is the single LC2 sender, so it arbitrates direction against hazard before sending one packet per heartbeat (safety wins; see [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md)). The cross-source deconfliction the ESP32 used to do stays in the firmware as a backstop only, in case the optional Coral stretch adds a second sender.

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

## Safety data flow (phone perception)

```
[Phone] LiDAR scene depth at ~10 Hz (and camera Vision frames for the stretch)
  -> [Phone] nearest distance per left/center/right band; person boxes (stretch)
  -> [Phone] settle + hysteresis + refractory filter (kills false positives)
  -> [Phone] if a hazard is settled: pick the quadrant mask from the closest band
  -> [Phone] arbitrate: hazard preempts the staged turn cue for this heartbeat
  -> [Phone] emit LC2 packet (0x40 obstacle-near from LiDAR, or 0x10 vision-danger from camera)
  -> [ESP32] render the sustained tap-train on the masked quadrant
  -> [Wearer] feels rapid taps on the affected side
```

The phone owns both "where to go" and "what is close in front of me," and merges them into one packet stream. The ESP32 owns "translate events into physical taps." The filtering and arbitration that keep the safety cue trustworthy live in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md).

## Why the phone and the ESP32 are separate

The split is deliberate. Each device does what it is uniquely good at:

- **Phone** is the only thing with GPS, a magnetometer, the cellular link to Google Maps, and the LiDAR plus camera that sense what is ahead. It is the sensing and the brain.
- **ESP32** is the only thing that can drive four PWM channels at a deterministic rate without being interrupted by a garbage collector or an OS scheduler. It is the actuator.

Putting the perception on the phone instead of a separate vision board removed a device, removed a second LC2 sender, and removed a cold-start learning risk. Running the servos straight off the phone would lose the deterministic PWM timing the ESP32 gives, so that split stays. If the optional Coral stretch ships, it rejoins as a second sender and the ESP32 deconfliction backstop covers it.

## Failure tolerance

- If the phone link drops, the ESP32 stops getting packets and falls back to idle (servos quiet) after 500 ms of silence. No false cues fire.
- If a sensor on the phone drops (no GPS, or LiDAR unavailable), that one tier goes quiet while the others keep working. A lost GPS fix stops turn cues; lost depth stops the proximity cue. Neither takes the other down.
- If everything drops, the wearer feels nothing. This is the right behavior. Feeling nothing is better than feeling a stale cue.
- If the ESP32 reboots, the heartbeat re-establishes and operation resumes. The 100 ms heartbeat cadence makes recovery invisible.
