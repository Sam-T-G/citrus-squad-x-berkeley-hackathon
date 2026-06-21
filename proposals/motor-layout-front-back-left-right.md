# Proposal: front / back / left / right belt motors

Status: proposed by Sam, 2026-06-20. Not adopted. Nothing in `firmware/` or `docs/` has been
changed by this proposal. This is a description for whoever owns those files to adopt when ready.

## The idea

Arrange the four motors as a cross around the torso instead of four across the chest:

```
        [ FRONT ]   forward / on course
           |
[ LEFT ]---+---[ RIGHT ]   rotate left / right
           |
        [ BACK ]    proximity (obstacle behind the warning)
```

- **Left** = rotate left, **Right** = rotate right (single tap = slight, triple = sharp)
- **Front** = forward / proceed straight
- **Back** = proximity warning (any obstacle, closeness rides on intensity)

Pattern still carries urgency, the motor carries meaning.

## What the phone app already does

The iOS app on this branch implements this layout already, so it can serve as the reference while
the firmware and protocol catch up. After adoption there is no app change needed. Until then, note
the app is ahead of the documented protocol: the app sends the new masks below, the committed
`docs/03` and reference firmware still describe the old far-left/left/right/far-right layout.

## Proposed protocol change (`docs/03-protocol.md`, for the docs owner)

Motor mask (byte 1):

| Bit | Mask | Motor |
|---|---|---|
| 0 | `0x01` | Front (forward) |
| 1 | `0x02` | Left (rotate left) |
| 2 | `0x04` | Right (rotate right) |
| 3 | `0x08` | Back (proximity) |

Combos: turn-around = Left + Right = `0x06`; arrived sweep = all = `0x0F`.

Events (byte 0): add one, repoint two.

| Code | Event | Motor | Note |
|---|---|---|---|
| `0x24` | forward (new) | Front | on course / proceed straight, single tap |
| `0x22` | turn-around | Left + Right (`0x06`) | both rotate motors |
| `0x40` | obstacle-near | Back (`0x08`) | proximity; closeness on intensity |
| `0x10` | vision-danger | Back (`0x08`) | same motor as obstacle-near |

The four-pattern cap still holds: forward reuses the single-tap pattern, proximity reuses the
sustained tap-train. No new pattern.

## Proposed firmware change (`firmware/citrus_squad_belt/`, for Angelo)

Only adopt if and when it suits the belt build. The diffs are small:

- `config.h`: rename the pins to `PIN_FRONT`, `PIN_LEFT`, `PIN_RIGHT`, `PIN_BACK` (same GPIOs, just
  relabeled to the new positions).
- `citrus_squad_belt.ino`:
  - servo order to match mask bits: `{ PIN_FRONT, PIN_LEFT, PIN_RIGHT, PIN_BACK }`
  - add `EV_FORWARD = 0x24`, handled as a single tap (same branch as turn-slight)
  - the obstacle / vision sustained train now lands on Back via the mask, no code change beyond the
    pin relabel
  - update the header comment's mask line to the new bits

## Open question

Front fires on every "on course" tick today, which the firmware's one-shot-per-cue logic turns into
a single tap when you enter the forward state (not a constant buzz). If a periodic reassurance tap is
wanted instead, that is a small firmware tweak. Worth deciding together.
