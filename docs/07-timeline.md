# 07 — Timeline

24-hour build window: **Saturday June 20, 11:00 AM** (H+0) through **Sunday June 21, 11:00 AM** (H+24). Judging and closing run H+24 through H+31 (Sun 6 PM). Default the schedule below, but do not skip the H+12 and H+20 gates.

## Block budget

| Block | Hours | When | Logic |
|---|---|---|---|
| Ceremony + idea sanity | 2 | H+0 to H+2 (11 AM – 1 PM Sat) | Opening ceremony. Confirm team direction. Final venue check on phone compass. |
| Scaffolding + sensor bring-up | 2 | H+2 to H+4 | App scaffold (already done), ESP32 firmware skeleton, depth read confirmed on the demo phone. Sponsor APIs decided. |
| Core loop (direction) | 8 | H+4 to H+12 | Single largest block. The full phone → ESP32 → servo direction path lands in this window. |
| H+12 GATE | — | 11 PM Sat | Direction M5 milestone target. Safety tier P-milestones (see [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md)). Camera stretch and optional Coral assessed. |
| Sleep window 1 | 2 | H+12 to H+14 | Half the team. Pitch person sleeps. |
| Polish + safety tier | 6 | H+14 to H+20 | Harden the safety tier (directional sampling, false-positive filtering, arbitration, thermal soak). Camera person-detection stretch ships here if time. |
| H+20 GATE | — | 7 AM Sun | Feature freeze. No new functionality past this point. |
| Demo path build + seeded mode | 4 | H+20 to H+24 | Replay cache. Backup video. Final hardening. |
| Devpost submission | 2 | H+22 to H+24 | Submit at H+22 even if rough. Devpost must be in before H+24. |
| Dry runs | 1 | H+23 to H+24 (overlaps Devpost) | Three runs minimum. Pitch person leads; others play judges. |
| Sleep window 2 | (folded into above) | — | Per-person opportunity to rest before judging. |
| Expo and judging | 1 | H+30 to H+31 (5 PM – 6 PM Sun) | Demo to every judge who walks by. |

Total build: 24 hours. Total event: 31 hours. Sleep target per person: 5 hours, accumulated across both windows.

## Critical-path milestones

These are the milestones that gate the demo. They must land in order; later milestones cannot start until earlier ones are green.

| Milestone | Owner lane | Target | Quality gate |
|---|---|---|---|
| **M0 — Bring-up** | All lanes | H+2 | App compiles. ESP32 firmware flashes. One UDP packet phone → ESP32 received within 100 ms. `DepthService` reads scene depth on the demo phone. |
| **M1 — Heading service** | Phone | H+5 | Body heading ±10° at rest. Calibration offset applied. |
| **M2 — Calibration UX** | Phone + belt | H+7 | Button captures offset. Confirmation pattern fires on the belt. |
| **M3 — Maps + bearing** | Phone | H+9 | Cached polyline. Body-relative bearing math correct on synthetic test. |
| **M4 — Quadrant + servos** | Phone + belt | H+11 | All four servos fire on synthetic inputs from all four quadrants. |
| **M5 — Full replay route** | All | H+12 | Walk the 30 m demo loop three consecutive times. All turn cues fire on the correct side. |
| **M6 — Safety tier** | Perception + belt | H+18 | LiDAR obstacle cue fires on the correct side, false-positive filtering and safety-over-direction arbitration are in, and the thermal soak passes (P0-P4 in `docs/12`). Camera person-detection is the stretch on top. |
| **M7 — Demo dress rehearsal** | All | H+22 | Three dry runs of the live pitch + demo. Pitch person reads from script. |

M5 is the line for "demo-able." Past H+12 with M5 still red, the team should consider scope cuts before sleeping.

## Gate decisions

### H+12 gate (Saturday 11 PM)

**Question 1: Is M5 green?** If no, identify the blocker. If the blocker is a one-hour fix, push to H+13 and continue. If it is a five-hour fix, drop the most complex piece (probably the calibration UX or the quadrant hysteresis) and re-run M5.

**Question 2: Is the safety tier on track for M6?** The LiDAR depth read is proven at M0, so the work left is the directional sampling, the false-positive filtering, the arbitration, and the thermal soak. If those are moving, M6 lands in the polish window. The camera person-detection stretch has its own cut: if it is not firing cleanly on a walk-in test, drop it and let the LiDAR cue carry the safety beat. The optional Coral stretch only continues if someone has spare hands and it cleared Friday's checkpoint.

### H+20 gate (Sunday 7 AM)

**Hard rule: no new features past H+20.** Anyone who proposes a new feature past this gate is overruled by the rest of the team.

**What does pass H+20:**

- Bug fixes for things that broke between H+12 and H+20.
- Pitch script refinement.
- Demo replay cache regeneration.
- Backup video recording (one 90-second demo video saved on the pitch person's laptop).

**What does not pass H+20:**

- New patterns, new event types, new sensors.
- New UI screens.
- Refactors of code that already works.
- "Just one more bonus feature."

## Sleep math

Total sleep budget: ~5 hours per person, distributed across two windows. The pitch person needs the most sleep (they will be on for hours during expo). Distribute as:

- Pitch person: 6 hours, mostly in the H+24 to H+30 window before expo.
- Tier-2 owner (Sam by default): 5 hours, half in H+12 to H+14, half before expo.
- Belt owner: 4 hours, opportunistic.
- Perception owner: 4 hours, mostly after M6 lands.

Sleep is the cheapest performance lever in the second half. Do not skip it because "we are almost done." Almost done at H+18 with no sleep means a fumbled pitch at H+30.

## What we do not spend time on

These eat hours and rarely change the pitch outcome. Decline them politely:

- Cross-platform support beyond the one demo phone.
- Code style consistency across teammates' files.
- README polish or marketing materials (the README and `docs/` already exist).
- "What if we showed it on a different track?" track-switching debates.
- Optimizing the model accuracy past the threshold that passes the trigger filter.
