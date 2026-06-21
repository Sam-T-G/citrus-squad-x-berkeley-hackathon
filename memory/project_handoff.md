---
name: project-handoff
description: README.md and HANDOFF.md must both be updated every commit on cole/computer-vision
metadata:
  type: feedback
---

Update `README.md` and `HANDOFF.md` at the repo root every time a meaningful commit is made on `cole/computer-vision`.

**Why:** Cole explicitly asked for this. The README is the public-facing summary of what the CV layer does and plans to do. HANDOFF.md is the integration contract between Cole (Python CV) and Sam (Swift iOS). Both rot fast during a hackathon and need to stay honest.

**How to apply:**
- README: update "What is built" and "Planned" sections to reflect current state
- HANDOFF: move open items to "What is built" as they land; add new open items as they emerge
- Both: update after every commit, in the same pass as the commit

The "Last updated" line in the HANDOFF CV section should reflect the session date.
