---
name: feedback-no-swift
description: Cole does not write or want to see Swift code; all CV work stays in Python
metadata:
  type: feedback
---

Do not generate Swift, iOS boilerplate, or Xcode UI code for Cole.

**Why:** Cole is the Python CV engineer on the team. Josh handles all Swift/iOS/LiDAR work. Cole explicitly said "I do NOT want to write or look at any Swift code."

**How to apply:** Any CV feature request from Cole gets a Python implementation only. If the task touches iOS integration, describe the interface/contract (e.g., WebSocket JSON format) but do not write Swift. Swift files already in `ios/` are for Josh.
