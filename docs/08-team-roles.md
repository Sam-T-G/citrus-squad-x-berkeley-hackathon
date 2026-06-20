# 08 — Team roles

Four people, four lanes. Lanes are sized so each person can ship their piece without blocking on someone else. Cross-lane handoffs are explicit and happen at specific gates.

## Lanes

| Lane | Default owner | Scope |
|---|---|---|
| **Tier-2 phone-IMU + Maps** | Sam | The phone app. Heading service, calibration UX, Maps integration, LC2 sender. Owns M1-M5 in the timeline. |
| **Belt firmware + servos + integration** | Cole | ESP32 firmware. Servo PWM driver. LC2 receiver and deconflicter. Bench-tests the four servo patterns. |
| **Coral vision (conditional)** | Josh OR Angelo | Tier-3. Mendel boot, model inference, trigger filter, LC2 sender. Owns the pre-event learning sprint Wed-Fri. Hands off to the team after the H+12 gate. |
| **Pitch + demo + safety** | The remaining of Josh / Angelo | Pitch script. Demo lane setup. Backup video. Operator role during demo (presses Calibrate, narrates). Becomes the public face Sunday. |

Default owner assignments are confirmed at the alignment meeting. Anyone can move lanes if the team agrees, but only at gate boundaries (H+0, H+4, H+12, H+20). Mid-block lane switches are how features get half-shipped.

## Cross-lane dependencies

These are the points where two lanes must agree on shape before either can ship. Resolve them as early as possible.

### LC2 packet contract (phone ↔ belt)

Owners: Sam + Cole. By M0 (H+2), both must agree on:

- The exact byte layout per [`03-protocol.md`](03-protocol.md).
- The IP + port if using UDP, or the UART baud + framing if using serial.
- The 10 Hz heartbeat cadence and the 500 ms idle-fallback rule.

Anything ambiguous in the protocol doc gets resolved here. If the two lanes have different implementations of the same byte, the demo dies.

### LC2 packet contract (Coral ↔ belt)

Owners: Coral owner + Cole. By M0 (H+2), both must agree on:

- Same byte layout as the phone-belt contract.
- Same IP/port or same UART pinout (Coral can share the ESP32 UART pins if BLE/UDP options are rejected).
- The deconfliction rule: Tier-3 wins on the affected quadrant.

This contract follows the same shape as the phone-belt contract, so the agreement is mechanical once Cole's firmware exists.

### Calibration trigger (phone ↔ belt)

Owner: Sam (phone button by default). If the belt push-button stretch ships, Cole adds a reverse-direction LC2 event and Sam handles it in the phone code. This contract is only live if the stretch ships; do not pre-commit firmware time to it.

### Demo lane (everyone)

Owner: pitch person. Saturday afternoon, the pitch person walks the demo lane and confirms:

- The GPS lock works at the demo location.
- The phone compass reads true within the venue test.
- The four servos all fire on the wearer.
- The backup video plays from the pitch person's laptop.

Each cross-lane handoff above must have produced an artifact by the time the pitch person runs the lane.

## Communication

Default channel: team Discord or Slack (whichever the team has). Rules:

- **Status pings every 90 minutes during waking hours.** One sentence per person: "M3 green, starting M4," or "blocked on UART framing, asking Cole." Not a standup, just a sanity check.
- **Blocker pings immediate.** If you are stuck for more than 20 minutes on something that another lane could unblock, ping. Don't suffer alone.
- **Decision pings explicit.** If you are about to make a choice that affects another lane, say so. "I'm going to use UDP port 4242, fine?" beats picking and hoping nobody minds.

## Sleep handoffs

When a lane owner sleeps, they hand off a one-paragraph "where I left it" note to the next person likely to touch their code. Includes:

- What's working right now.
- What's broken right now.
- The first thing to try when you pick it up.
- Anything not to touch.

The handoff note lives in a pinned chat message or in a `HANDOFF.md` at the repo root that gets overwritten each sleep cycle. Whichever the team finds easiest.

## When lanes merge

Past M5 (H+12), lanes start merging. The pitch person + Tier-2 owner walk the demo lane together. The belt owner watches the servos fire and tunes intensity. The Coral owner (if vision shipped) tests trigger threshold on the demo wearer.

By H+20, the team is one lane: demo polish and pitch rehearsal. Treat the last 4 hours of build as "rehearse what works" not "build more."

## Conflict resolution

Disagreements happen. Use this order:

1. **Re-read the relevant doc.** If the doc answers the question, the doc wins. Fix the doc if it's wrong.
2. **Smallest viable change wins.** If two approaches both work, take the one that requires less code.
3. **Defer to the lane owner.** The person who knows the code best has the most context.
4. **Defer to the pitch person on demo-visible choices.** They are the one who has to explain it.
5. **Sam breaks ties on architecture choices.** He is the one tracking the cross-doc consistency.

Do not let a disagreement run more than 10 minutes. Time spent arguing is time not spent shipping.
