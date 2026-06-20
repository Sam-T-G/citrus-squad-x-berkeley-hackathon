# Documentation index

Living plans and specifications for the Citrus Squad × Berkeley AI Hackathon 2026 build. Teammates push directly to these files; everything in `docs/` is shared canon.

## Reading order

If you are picking this up fresh, read in this order:

1. [`00-overview.md`](00-overview.md) — what we are building and why
2. [`01-architecture.md`](01-architecture.md) — system shape and data flow
3. [`02-hardware.md`](02-hardware.md) — bill of materials, pinout, harness
4. [`03-protocol.md`](03-protocol.md) — LC2 packet format
5. [`04-phone-side.md`](04-phone-side.md) — phone-IMU heading, Maps, calibration
6. [`05-vision-tier.md`](05-vision-tier.md) — Coral vision safety (conditional)
7. [`06-failure-modes.md`](06-failure-modes.md) — what goes wrong, how we react
8. [`07-timeline.md`](07-timeline.md) — 24-hour build plan with gates
9. [`08-team-roles.md`](08-team-roles.md) — who owns what
10. [`09-demo-and-pitch.md`](09-demo-and-pitch.md) — demo plan and pitch beats
11. [`10-validated.md`](10-validated.md) — what we have already verified
12. [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md) — phone-app build contract (resolves 03 + 04 into one decision function)
13. [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md) — phone LiDAR + camera safety tier, demo and user hardened

The Swift implementation runbook lives at the repo root in [`HANDOFF.md`](../HANDOFF.md). Read it when picking up the iOS app.

## Update protocol

- When you change a spec, write the change directly in the relevant doc. No append-only log; the docs are the source of truth.
- If a decision contradicts another doc, fix both in the same PR. Drift between docs is worse than either version.
- Direction is fluid until the alignment meeting locks scope. Anything in here labeled "current" can change in the first hour of the hack.

## Voice

Read `CLAUDE.md` at the repo root for voice rules. Short version: write like a sharp teammate, not a deck.
