---
name: project-handoff
description: HANDOFF.md exists at repo root and must stay current as CV work changes
metadata:
  type: project
---

`HANDOFF.md` lives at the repo root. It is the primary handoff between Cole (CV) and Josh (iOS/LiDAR/haptics).

**Why:** Cole asked for a handoff doc that is kept updated. It covers wire protocol, WebSocket endpoints, output JSON schema, depth fusion logic, navigation class list, tuning knobs, and open items.

**How to apply:** Any time the CV layer changes in a way that affects Josh's integration (wire format, output schema, new fields, tuning defaults, new endpoints), update `HANDOFF.md` in the same session. Also update the "Last updated" date at the top.
