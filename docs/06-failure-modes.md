# 06 — Failure modes

A red-team list of what can go wrong, ranked by impact on the demo. Each entry has a trigger, a mitigation, and a recovery action the team should rehearse before the hack.

## Existential (kills the demo)

### F1. Phone compass unreliable in the venue

**Trigger.** Steel framing or magnetic interference in the venue room makes the magnetometer reading wander or stick. The wearer is told to turn left when the actual direction is right.

**Mitigation.** Friday venue gate. Friday morning, walk the demo room with the phone open and the compass UI visible. Compare the reading against a known-true compass (a second phone, or a physical compass). If the demo-room reading drifts more than 15° within 30 seconds while standing still, the venue is bad and we cannot ship Tier-2 in that room.

**Recovery if it fails Saturday.** Re-pick the demo lane to one with less interference. If no clean lane exists, cut the phone-IMU heading layer and ship the "torso-forward assumed" fallback (the wearer must keep their body pointed roughly along the route). This degrades the experience but is honest.

### F2. Free-tier Apple Developer cert expires mid-hack

**Trigger.** Apple's free developer signing gives a 7-day cert. If the demo app was installed too early, the cert can expire between install and demo.

**Mitigation.** Install the demo build no earlier than Friday afternoon. The 7-day window then covers through next Friday, comfortably past the Sunday demo.

**Recovery.** Re-install on the spot. Requires the demo Mac and a USB cable. Takes ~3 minutes if Xcode is already open with the right project.

### F3. Demo phone dies or loses Wi-Fi during the pitch

**Trigger.** Battery, Wi-Fi handoff, judge crowd interference.

**Mitigation.** Keep the phone on a charger between runs. Test the demo path on the actual venue Wi-Fi (or whatever network the demo uses) at least once Saturday afternoon.

**Recovery.** Switch to the backup demo phone. Pre-install the build on the backup phone Friday night so the swap is plug-and-play.

## Silent killers (work for a while, then break)

### F4. ESP32 brownout under simultaneous servo actuation

**Trigger.** The sweep pattern fires all four servos at once. Peak current can exceed the power bank's rated output, sagging the rail enough to reboot the ESP32. Symptom: random ESP32 reboots during certain demo segments, not all the time.

**Mitigation.** Bulk capacitor (1000 μF or larger) across the 5 V servo rail. Power bank rated ≥2.1 A. Stagger servo actuation in the sweep pattern by ~20 ms per servo instead of firing all four simultaneously.

**Recovery.** Replace the power bank with a spare. If brownouts persist, drop the sweep pattern from the demo and use a simpler arrived signal (single tap on Far Left, then Far Right).

### F5. Wi-Fi congestion at the venue

**Trigger.** 1,300+ hackers in one room. Wi-Fi spectrum is saturated. LC2 packets see 200-500 ms latency instead of the expected sub-50 ms.

**Mitigation.** Use a dedicated travel router with its own SSID. Set the router to a clean 2.4 GHz channel after scanning Saturday morning. Or use phone hotspot, which gives the phone control of the airtime.

**Recovery.** Switch to UART (Coral) and a tethered demo where the phone is plugged into the belt by USB. This is the nuclear option; only ship if Wi-Fi is genuinely unworkable.

### F6. Servo signal level is marginal

**Trigger.** Hobby servos expect 5 V PWM. The ESP32 outputs 3.3 V. Most servos work anyway, but some twitch or fail to recognize the signal at boundary cases.

**Mitigation.** Bench-test all four active servos with the ESP32 at the M0 gate. If any servo is marginal, add a logic-level shifter on its signal line.

**Recovery.** Swap to the spare servos (which may have different sensitivity). Or wire in a PCA9685 PWM controller for clean 5 V output across all four channels. Adds ~30 minutes of work.

### F7. Coral camera frame drops

**Trigger.** USB camera driver under Mendel Linux drops frames intermittently. Trigger filter never sees three consecutive frames, so vision-danger never fires.

**Mitigation.** Use the Coral Camera (CSI interface) if it works. Fall back to a known-good USB webcam (Logitech C920 class). Test 5 minutes of continuous capture at the M3 milestone.

**Recovery.** Reset the camera (unplug-replug). If it persists, the Tier-3 layer cuts at the next gate.

## Annoyances (degrade but do not kill)

### F8. Servo audible click

**Trigger.** Servo gear trains make a click on each direction change. At the 10 Hz sustained tap-train pattern, the clicks become continuous and audible in a quiet demo room.

**Mitigation.** Bench-test the audibility at the M2 milestone. If the clicks are loud, slow the tap-train cadence from 10 Hz to 6 Hz.

**Recovery.** Demo in a slightly louder room; venue chatter masks the clicks. Or skip the vision tier (no sustained tap-trains) and ship Tier-2 only.

### F9. Wearer cannot distinguish patterns

**Trigger.** Under demo stress, the wearer cannot tell single tap from triple tap. Either the intensity hint is wrong or the pattern timing is off.

**Mitigation.** Walk the demo wearer through the four-pattern vocabulary at the M2 bench test. If they cannot reliably distinguish them after three passes, widen the timing gaps.

**Recovery.** Drop one pattern from the demo (probably turn-around, which is the least-used). The vocabulary becomes 3 patterns and the demo accommodates.

### F10. Compass low-confidence flag persists

**Trigger.** The OS reports low magnetometer confidence for a long stretch. Heading service degrades silently.

**Mitigation.** Show a "low confidence" indicator in the phone UI. If the flag persists across two consecutive samples, prompt the operator to recalibrate.

**Recovery.** Force a hard recalibration. If that does not clear the flag, the wearer is in an interference zone (steel framing nearby); move the demo lane.

## Recovery rehearsals

Before the hack, rehearse the recovery for at least F1, F4, and F5. The team should be able to:

- Run the venue gate test and read the result without consulting documentation.
- Swap power banks in under a minute.
- Switch the phone hotspot on as a fallback for the travel router.

Each recovery should be a single tested action, not a discussion. If a recovery requires team-wide debate at demo time, it does not count as a recovery.
