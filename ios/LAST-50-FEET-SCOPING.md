# Last-50-Feet Final Approach — Scoping Document

Lead architect's buildable spec for the door-level final-approach wedge. This is the
unbuilt half of the #1+#2 community need: get the wearer from "GPS put me within
5-25 m" to "my hand is on the actual door / the bus pole / the right counter." The
reading half (the honest camera reader) already ships. This document decides the
anchor tech, the ARKit pipeline, the non-visual guidance channel, where Claude helps
and where it must not, the MVP, the build plan, and the validation gates.

Every load-bearing code claim below was checked against the actual `ios/Sources` tree,
not the design prose. Where a design's framing was wrong, this document says so and
corrects it, because the adversarial reviewers were right on the facts.

---

## 1. The wedge in one paragraph, and what it does NOT claim

We give a blind or low-vision traveler a non-visual "getting warmer, turn toward it"
beacon that walks their hand from roughly fifteen meters out onto a specific
destination they chose by voice (a door, a counter, a bus pole), inside an
environment we instrumented with printed markers, then confirms arrival by reading
the real-world sign. The phone is chest-mounted; ARKit drives a metric bearing-and-
range fix off a printed marker, a barcode payload on that same marker carries the
semantic label so we know which thing it is, and the existing honest reader closes
the loop. The whole time-critical path is on-device and offline.

It does **not** claim door-level precision in arbitrary un-mapped buildings. That is
the open research problem, full stop; in an uninstrumented venue the app degrades
honestly to the reader and says "I can't place this door precisely." It does **not**
do obstacle avoidance, stairs, drop-offs, street crossings, or any steer/stop. The
cane and the wearer own the next ~1.2 m and every hazard decision; the beacon only
guides toward a destination the wearer chose to walk to, and it never commands around
a hazard. It does **not** speak a distance from vision, ever. It does **not** replace
the cane, duplicate it, or block its tactile and echo feedback. And it does **not**
promise retention until blind co-designers and an O&M instructor have tuned it
(Section 8) — a demo that works on stage is not the claim; a tool still used in six
months is.

---

## 2. Chosen architecture, and the trade-off named

**Decision: a hybrid two-channel anchor, ARKit `ARImageAnchor` as the primary
positioning layer and a `VNDetectBarcodes` payload as the semantic layer, both read
off the same printed marker, both behind one `AbsoluteAnchorSource` protocol.**

The judging round crowned the pure-barcode design (Design 4) for the right strategic
reasons — small-team fit, durability, honesty, no proprietary lock — but two of its
load-bearing feasibility claims are false against this codebase, and the adversarial
iOS review verified both:

- **The "free decode off the existing cache" claim is wrong.** `latestVisionFrame`
  (DepthService.swift:176) refreshes at `frameTick % 30` *inside* the
  `frameTick % 6 == 0` + `frame.sceneDepth` guard at line 162 — roughly 0.3 Hz, and
  only when a depth map is present. That is the pull-on-demand frame for Claude, not
  a live decode stream. A warmer/colder cue that needs frame-to-frame decode
  consistency cannot run off 0.3 Hz. Either design needs a real net-new ~10 Hz
  perception branch.
- **The "barcode needs no spatial audio" claim is wrong and asymmetric.**
  ChimePlayer (ChimePlayer.swift:25) is mono, `channels: 1`, wired straight to
  `mainMixerNode`. To convey "turn toward it" you need left/right panning regardless
  of anchor tech. Cadence conveys range, not bearing. So all four designs need at
  minimum a panned beacon node; barcode does not escape that cost.

Once those two are corrected, pure barcode's real ceiling is exposed: a paper
QR/Aztec on a moving, blindfolded, chest-mounted, non-frontal aim decodes reliably
only inside roughly 1-3 m and roughly frontal. That owns the last ~6-10 feet, not the
last 50. The wedge is literally named the last fifty feet.

`ARImageAnchor` closes that gap for nearly the same build effort. Adding
`config.detectionImages` to the existing `ARWorldTrackingConfiguration` and one
anchor branch on the existing delegate gives a tracked 6DoF pose, with metric bearing
and range, and ARKit keeps reporting the anchor's position as the wearer moves and as
the marker briefly leaves frame. That continuity is exactly the 15 m bridging that
barcode-only lacks. So the marker carries *both*: an `ARReferenceImage` for the metric
fix and a barcode payload (`DOOR:room-214`) for the label. ARKit answers *where*;
the barcode answers *which one*; Claude answers *what the real sign says*.

**The trade-off, named, not dodged:**

- **What we gain over pure barcode:** continuous bearing+range that actually walks the
  15 m, not a decode lottery that only locks when you are nearly touching the sign.
- **What we pay over pure barcode:** ARKit metric distance depends on the registered
  `physicalWidth` being correct; a mis-measured print silently lands the anchor at the
  wrong distance. This is a quiet-failure twin of the belt's no-ack UDP link. We treat
  the print width as a calibrated per-marker constant, verified against a tape measure
  at install, recorded in the venue map. We also re-import a thin slice of VIO-drift
  management (Section 3) that pure barcode deletes entirely — but the drift budget over
  a single 15 m hop with the marker in or recently in frame is tens of centimeters,
  comfortably inside a door-level budget.
- **Why not full metric pose with AprilTag/solvePnP (Design 3):** highest open-source
  purity and the sharpest low-false-positive argument, but AprilTag has no official iOS
  support and pulling OpenCV into a build with zero such dependency is real weight in a
  hackathon window. It is the documented post-hackathon upgrade backend, not the MVP.
- **Why not NaviLens:** it is the genuine north star on raw spec (18 m, 160° field,
  focus-free, reports distance+bearing) and the right partnership target, but the color
  codec is patented and closed with no royalty-free SDK. We design *to* its behavior and
  name it as the licensable upgrade; we never treat it as self-printable infrastructure.
- **Why not plain QR alone:** no native 6DoF pose, needs frontal aim and focus — it
  fails on the exact aiming tolerance the wedge exists to solve. We use the barcode
  *only* for the semantic payload, never as the positioning signal, and we prefer Aztec
  or DataMatrix over QR for blind-aim tolerance (Vision decodes both).

The `AbsoluteAnchorSource` protocol is the durability hedge: ship `ARImageAnchor` now,
slot AprilTag/solvePnP or a NaviLens partnership backend in later without touching the
beacon, the matcher, the belt mapping, or the reader.

```swift
protocol AbsoluteAnchorSource {
    /// A metric fix to the active target, or nil when no anchor is currently resolved.
    func fix(forTarget id: String) -> AnchorFix?
}

struct AnchorFix: Sendable {
    let targetID: String
    let bearingRadians: Double      // signed, relative to phone/torso heading
    let rangeBucket: RangeBucket    // .far .near .here — never a spoken metric distance
    let isLive: Bool                // true = anchor seen this frame; false = ARKit-extrapolated
    let label: String?             // from the barcode payload, nil if decode not yet matched
}

enum RangeBucket: Sendable { case far, near, here }
```

---

## 3. The ARKit positioning pipeline, concretely

One shared `ARSession`. The session already runs in DepthService on
`ARWorldTrackingConfiguration` with `frameSemantics = .sceneDepth` (DepthService.swift:130-132)
feeding the deterministic obstacle reflex. **The final-approach layer is additive to
that exact configuration.** The trap to avoid, verified in the research, is
`ARImageTrackingConfiguration` — a separate config that gives faster image tracking but
drops world tracking *and* LiDAR. We stay on `ARWorldTrackingConfiguration` so scene
depth keeps feeding the obstacle reflex with no contention.

**Anchors → absolute pose.** In `start()`, set
`config.detectionImages = <ARReferenceImage set>` and
`config.maximumNumberOfTrackedImages = 4`. On `ARImageAnchor` detection in the existing
`ARSessionDelegate`, ARKit hands back the marker's full 6DoF transform in the session
world frame. The active target's true position is the anchor transform composed with a
surveyed offset stored in the per-venue map (the marker may sit beside the door, not on
it). From the wearer's current `frame.camera.transform` and the target transform we
compute a signed bearing and a three-bucket range each tick. **No custom VIO math for
the in-frame case** — ARKit owns the geometry.

**VIO dead-reckoning.** Between sightings, ARKit world tracking carries the wearer's
6DoF pose and keeps reporting the (now stationary) anchor's position, so bearing+range
stay live through brief occlusions — a chest-mounted arm, cane, or coat crossing the
frame. This is the bridging that pure barcode cannot do. Benchmarked ARKit relative
drift is ~0.02 m/s with ~0.09-0.26 m final error over 50-69 m indoor loops, best of the
commercial VIO systems tested. Over a single ~15 m approach the accumulated drift is
tens of centimeters.

**Re-anchor cadence.** The marker resets odometry on every fresh sighting. Tag density
is set by the drift budget: a fix at least every ~10-20 m of travel keeps drift under a
sub-meter ceiling. For a single 50 ft approach the marker usually stays in or near frame
the whole way, so drift barely accumulates. We never trust un-anchored building-scale
traversal — that is a different (un-built) problem.

**Drift budget, stated.** Budget ceiling: < 1.0 m at the moment of "here." Drift sources:
(a) VIO accumulation ~0.02 m/s, bounded by re-anchoring; (b) registered `physicalWidth`
error, bounded by tape-measure calibration at install; (c) survey-offset error in the
venue map, bounded by a single careful measurement. Environmental degraders — feature-poor
lobbies, blank walls, glass, reflective floors, crowds, low light — are exactly the target
spaces and are the real risk. Mitigation is keeping the marker in or near frame as the
continuous reset, plus the loud re-aim loop in Section 4. The controlled demo lighting
hides this; we say so on stage.

**Shared-session discipline.** Two facts make this safe to graft:

- DepthService already pulls `frame.capturedImage` and `frame.sceneDepth` off one serial
  `perceptionQueue` (DepthService.swift:35, 160-190). The barcode branch and the image-
  anchor branch ride the same delegate callback — no second camera, no config switch.
- **The barcode decode is net-new perception work, not a free cache read.** We add a
  dedicated `VNDetectBarcodesRequest` branch in `session(_:didUpdate:)`, *outside* the
  depth guard at line 162, throttled to ~8-10 Hz on `frame.capturedImage`, on the
  existing queue, gated by the same `visionEnabled` flag the thermal ladder toggles. The
  framework is already imported and `VNImageRequestHandler` already runs in
  PersonDetector.swift, so this reuses a proven pattern — but it is a real branch with a
  real thermal cost, scoped as such, not a one-liner.

```
ARFrame (one shared session, ~60 Hz)
  │
  ├─ frameTick % 6  → sceneDepth band scan ──→ obstacle reflex (UNCHANGED, deterministic)
  │
  ├─ ~10 Hz (NEW)   → VNDetectBarcodes on capturedImage
  │                     → decoded "TYPE:label" + bounding box + confidence
  │                     → N-consecutive-frame consistency before a match is declared
  │
  ├─ on ARImageAnchor detect (NEW branch on existing delegate)
  │                     → metric 6DoF anchor transform
  │                     → compose surveyed offset → target world pose
  │                     → bearing + 3-bucket range each tick (ARKit-continuous)
  │
  └─ frameTick % 30 → latestVisionFrame cache (UNCHANGED, ~0.3 Hz, for Claude read)
```

The barcode match and the metric fix are fused on `targetID`: the anchor gives the live
geometry, the barcode confirms the label is the one the wearer asked for. If the metric
anchor is live but the label has not matched yet, we beacon toward the geometric fix and
hold the spoken confirmation until the label or the reader agrees — we never announce
"arrived at room 214" on geometry alone.

---

## 4. Conveying final approach non-visually, without crossing describe-don't-decide

**Decision: a spatialized audio beacon is primary; the belt is an optional, flagged,
coarse-bearing echo; spoken voice is on-request only. Range is encoded as cadence, and
where LiDAR can see the target, cadence is driven by depth, not by bounding-box growth.**

### Belt vs voice vs beacon — the decision, with reasons

- **Belt is demoted off the final-approach guidance path by default.** The feelSpace
  evidence backs torso haptics only for coarse direction and confidence, not safety-
  critical fine positioning, and the north star is unambiguous that the belt is the most
  stigmatizing, least-proven, abandonment-prone part of the system. During approach it
  may, behind a flag, echo coarse bearing on the existing rotate events
  (`turnSlight` 0x20 left/right, `forward` 0x24) and fire the existing `arrived` 0x23
  sweep — direction and confidence only, never fine positioning, never a stop, never a
  steer-around-a-hazard. **Two blocking preconditions before the belt carries any
  approach bearing:** resolve the mirrored left/right band bug (DepthService.swift:268
  carries a literal "if mirrored, swap these" comment — a 50/50 left-means-right
  inversion on a directional cue is a safety inversion, not a footnote), and give the
  belt a liveness return path so a dead UDP link feels different from "clear." The
  deterministic obstacle reflex keeps the Back motor (`obstacleNear` 0x40) as its own
  separate owned channel; final approach never touches it. One job per motor — the
  multi-job ambiguity is the cognitive-overload trap that killed sensory substitution.

- **Voice (speech) is on-request only, never the continuous channel.** On request, a
  terse 5-7 word line (clock-face default — "door at eleven o'clock" — with a left/right/
  ahead fallback for younger users), carrying bearing class plus close/closer/here,
  never a vision-derived number. This reuses the existing Deepgram agent, the
  `setDestination`/`readSign`/`locateEntrance` voice commands (VoiceCommand.swift:6-14),
  and the `VisionRead` reader contract.

- **The audio beacon is the primary in-the-moment channel** — the All_Aboard /
  Soundscape informant pattern. A repeating pulse panned toward the target bearing; the
  wearer walks toward a sound they chose to follow. This is an informant cue, not a steer
  command, so it stays on the right side of describe-don't-decide by construction.

### The honest beacon spec, corrected for what the codebase actually has

ChimePlayer is mono with zero pan (verified). **The beacon is net-new audio work for
this design too**, and the honest framing is "needs pan, not full HRTF," a smaller delta
than a PHASE/HRTF rebuild but not free:

- **Bearing → stereo pan.** Build a two-channel `AVAudioEngine` beacon node with a
  per-buffer pan derived from the signed bearing. Cheapest correct version: stereo pan on
  the existing engine. The `AVAudioEnvironmentNode`/PHASE world-locked source is the
  documented upgrade, gated behind the same `AbsoluteAnchorSource` seam, not the MVP.
  Because the phone is chest-mounted, panning follows torso/phone heading, not head
  heading — coarser than AirPods head-tracked audio, and we disambiguate by motion plus
  the on-axis tone below, not by raw localization.

- **Range → cadence, depth-driven where possible.** Pulse cadence rises as the target
  closes (far = slow, near = fast, continuous tone inside ~1 m = "here"). **Drive cadence
  from LiDAR `sceneDepth` at the target's screen position when the target is in depth
  range**, not from bounding-box growth — DepthService already computes per-band metric
  depth from the same frame (DepthService.swift:235-270), so this is a drift-free,
  platform-given distance we would otherwise throw away. Describe-don't-decide forbids a
  *spoken* vision distance, not a depth-driven non-verbal tone. Fall back to the
  ARKit-anchor range bucket when the target is outside the depth cone (depth tops out
  around a few meters; the anchor carries the longer range).

- **On-axis confirmation tone — the single best beacon idea in the field, grafted.** Fire
  a distinct tone when the target's bearing stays within a few degrees of dead-ahead for
  several consecutive ticks, so the wearer's torso becomes the pointer. This is cheap in
  *this* hybrid (the ARKit anchor gives continuous bearing, so "centered for N ticks" is
  well-defined) in a way it would *not* be in pure barcode (sporadic decodes give too few
  consecutive centered frames). It is one more reason the hybrid is the right call.

- **Open-ear, hard constraint.** Hearing is navigation infrastructure — blind travelers
  localize traffic, silent EVs, cyclists, and building echoes by ear, and headphone audio
  that masks them is a net safety loss the north star names explicitly. The current
  VoiceSession forces the bottom speaker
  (`.defaultToSpeaker` + `overrideOutputAudioPort(.speaker)`, VoiceSession.swift:104-108).
  A continuous mono chest-speaker tone is the wrong default for this population. **The
  beacon must route to bone-conduction or open-ear, with reserved loudness; this is a
  blocking constraint, not a preference.** It is a real audio-routing task, scoped in the
  build plan.

### Composing with the honest reader

The reader is the arrival truth-test, and it is the guard against the one failure the
barcode payload can produce silently: a mislabeled, swapped, or vandalized sticker that
beacons the wearer confidently onto the wrong door. The decoded label is always a
machine-readable *hint*; the human-readable sign read by Claude is the ground truth the
wearer acts on. Sequence:

1. Beacon + cadence + on-axis tone walk the wearer to "here" on the metric fix.
2. The barcode match says the label *should* be the chosen target.
3. On arrival (or on request), `ClaudeClient.read` returns a `VisionRead` of the real
   sign — `spokenLine`, `legible`, `aimHint`, `confidence`, `highStakes`
   (ClaudeClient.swift:235-260) — confirming "this says ROOM 214," hedging high-stakes
   reads, coaching a re-aim on a bad frame.
4. If the label and the read disagree, the read wins and the wearer is told plainly.

**Silent-failure-of-absence is a first-class, built-before-the-happy-path state.** When
no anchor is live and no fix is fresh, the system *says so* — "no marker in view, I can't
place this" — and runs an active "pan slowly to re-acquire" loop. A quiet beacon must
never read as "arrived." For the hybrid, absence during the hard part of the walk is
rarer than in pure barcode (ARKit bridges occlusions), but the announced-absence + re-aim
loop is the dominant-state UX whenever tracking is genuinely lost, and it ships first, as
a demo beat, not an afterthought.

---

## 5. Where Claude adds value in this wedge — and where it must not

**Claude is entirely off the positioning and safety path, mirroring the discipline
already applied to the belt: every `ClaudeClient` failure returns nil and falls back to
a grounded line, and nothing AI gates the belt or the beacon.**

Pose estimation is deterministic ARKit/Vision geometry. Keep AI out of it — VLMs cluster
at 38-52% distance error and answer spatial questions confidently when they cannot tell.
Three jobs for Claude, all semantic, none gating any cue or any timing:

1. **Arrival confirmation (already built).** Once the beacon puts the wearer in range,
   `ClaudeClient.read` reads the real sign to confirm the destination, with calibrated
   uncertainty and a high-stakes hedge. This turns a geometric/label fix into a
   semantically verified arrival and is the guard against a mislabeled marker.
2. **Destination disambiguation (conversational).** When two plausible labels decode in
   frame ("there is a pharmacy counter and a photo counter — which one?"), or the spoken
   destination does not map cleanly to a printed label, Claude resolves intent through the
   Deepgram agent and the existing `setDestination` command. The deterministic matcher
   handles exact matches; Claude is invoked only on genuine ambiguity, so it never sits in
   the hot loop.
3. **Graceful degradation in uninstrumented venues.** With no marker present, hand off to
   the existing `locateEntrance`/`readSign` honest reader — coarse direction only, never a
   stated distance — and announce reduced precision.

**Where Claude must not go:** it never estimates position, never computes or speaks a
distance, never gates the beacon, the belt, or any timing, and is not on the offline
critical path. If the network is dead, the metric fix, the cadence beacon, and the belt
echo all still work; only the conversational disambiguation and the confirming read
degrade, and the app says so. `SpokenLineGuard.withoutVisionDistance`
(SpokenLineGuard.swift:36) already enforces the no-vision-distance rule in code if the
model slips — keep it on every spoken line in this wedge.

**One honesty gap to close (from the abandonment lens):** the mislabel guard currently
relies on a network read. Offline, a swapped sticker beacons a blind user onto the wrong
door with the correctness guard gone. Either make the confirming read offline-capable with
on-device OCR (`VNRecognizeTextRequest` — same Vision framework already imported), or stop
calling the offline path safe to *act on* and have the beacon say "I can place this but
can't confirm the label offline." Scoped as a milestone item, not waved away.

---

## 6. The MVP demo slice

The smallest thing that proves the wedge on the one demo iPhone 15 Pro Max, in one
instrumented space we control, fully offline on the time-critical path.

**Space:** one short indoor run in the MLK building — a hallway and a target door — that
the team fully controls, so there is zero venue-permission burden (the documented
category killer; see Section 8). Print the marker set as **4-6 redundant copies per
decision point** at torso-to-eye height, on matte stock, high contrast, so one occlusion,
glare angle, or focus-hunt does not look like silent success. Each marker carries an
`ARReferenceImage` *and* an Aztec/DataMatrix payload (`DOOR:room-214`). A decoy door
nearby carries `DOOR:room-216` to demonstrate disambiguation. Register each marker's
`physicalWidth` (tape-measured) and its surveyed offset to the target in a per-venue JSON.

**Flow:**

1. Wearer says "take me to room 214" (`setDestination`, existing).
2. Eyes-closed walk, chest phone. ARKit detects the marker, latches the metric anchor;
   the ~10 Hz barcode branch decodes `DOOR:room-214` and confirms the label.
3. The panned beacon pulses faster as the wearer closes (depth-driven cadence near the
   door, anchor-bucket cadence farther out); the on-axis tone fires when the torso faces
   the door; a continuous tone sounds at arm's reach.
4. The decoy `216` decoding alongside triggers one Claude/voice disambiguation line
   ("two doors, 214 and 216, heading to 214").
5. At arrival the wearer asks "what does this say" and `ClaudeClient.read` confirms "this
   says ROOM 214" with its confidence hedge.
6. **Show the absence state on purpose:** cover the markers and let the system announce
   "no marker in view, I can't place this — pan to re-acquire." Then show the
   honest-reader fallback.

**What it proves:** sub-meter at the final marker, continuous guidance across the real
15 m gap (not just the last 6 feet), describe-don't-decide held, the cane assumed and
untouched, the offline beacon working with the network off, and absence handled honestly.

**Engineering footprint, scoped honestly (the net-new work, not "one line"):**

- One `ARImageAnchor` branch on the existing `ARSessionDelegate`, plus
  `detectionImages` on the existing config.
- One ~10 Hz `VNDetectBarcodes` branch in the delegate, outside the depth guard, on the
  existing queue, behind `visionEnabled`.
- One deterministic `FinalApproachController` computing bearing + 3-bucket range and the
  N-frame label-match consistency.
- One **panned, open-ear** beacon node (net-new; ChimePlayer is mono) with depth-driven
  cadence and the on-axis tone.
- Reuse: the honest reader, the voice commands, the LC2 belt events, the SpokenLineGuard.

**De-risked because** All_Aboard (1.54 m, distance-coded audio, no steer), NaviLens (the
spec target), Clew (VIO retrace between fixes), and Soundscape (beacon design) each
independently validate one sub-piece.

---

## 7. Milestoned build plan, with the cut line and the research-risk parts

**Phase 0 leads the plan, before any beacon grammar is frozen (non-negotiable — Section 8).**
The build below assumes Phase 0 is in motion in parallel, not deferred.

| # | Milestone | What ships | Risk |
|---|-----------|-----------|------|
| 0 | **Co-design + blocking fixes** | Blind co-designer + O&M instructor in the room; resolve the mirrored left/right band bug as blocking; belt liveness return path | none technical; the named top abandonment predictor |
| 1 | **Metric fix to one target** | `ARReferenceImage` + `ARImageAnchor` branch on the existing config; live (bearing, range-bucket) to one surveyed target; calibrate `physicalWidth` against a tape measure | low — additive to a session that already compiles and runs |
| 2 | **Panned open-ear beacon** | Two-channel beacon node; bearing→pan, depth-driven cadence→range, on-axis confirmation tone, continuous "here"; routed to bone-conduction/open-ear | **medium — net-new audio, ChimePlayer is mono; open-ear routing is real work** |
| 3 | **Semantic label layer** | ~10 Hz `VNDetectBarcodes` branch; Aztec/DataMatrix payload; N-frame consistency before a match; fuse with the metric fix on `targetID` | low-medium — proven Vision pattern, but a real perception branch and thermal add |
| 4 | **Absence + re-aim as first-class state** | Announced "no marker" + active "pan to re-acquire" loop; built before the happy path is polished | low; this IS the dominant-state UX when tracking is lost |
| 5 | **Arrival confirmation + disambiguation** | Point the existing reader at the destination; one-line Claude disambiguation on multi-label frames | low — reuses shipped surfaces |
| --- | **▼ CUT LINE — everything above is the demo ▼** | | |
| 6 | Belt coarse-bearing echo (flagged, OFF by default) | Echo bearing on `turnSlight`/`forward`; `arrived` sweep — only after Milestone 0 fixes land | gated behind blocking belt fixes |
| 7 | Offline mislabel guard | On-device `VNRecognizeTextRequest` so the correctness check survives a dead network | medium |
| 8 | Thermal governor | Automatic actuator on `.serious`: shed the barcode branch + YOLO tier, drop to beacon-only | medium |
| 9 | `AbsoluteAnchorSource` upgrade backends | AprilTag/solvePnP; NaviLens partnership backend | research/partnership |

**The cut line:** Milestones 1-5 are the demo. If time collapses, the irreducible
demo is Milestone 1 (metric fix) + Milestone 2 (beacon) + Milestone 4 (absence state) —
continuous guidance to one door with honest failure. The label layer (3) and confirmation
(5) are the next to drop, in that order, because the metric fix alone still walks the
wearer to the door; it just cannot yet *name* it.

**Research-risk parts, called out so they are not discovered on stage:**

- **The open-ear panned beacon (Milestone 2)** is the single most under-scoped shared cost
  across every design and the most likely to eat the window. Start it day one.
- **VIO in feature-poor lobbies / glass / crowds** — the exact target spaces. Bounded by
  keeping the marker in frame; un-bounded if the demo space is genuinely featureless.
  Rehearse in the actual demo lighting and geometry.
- **Thermal with no automatic governor.** ThermalMonitor (ThermalMonitor.swift) is a
  sampler/logger; the only actuator is the manual `visionEnabled` gate. Adding the barcode
  branch on top of the already-running YOLO tier + LiDAR + camera + radio under a chest
  strap on an iOS 27 beta will hit `.serious` well under five minutes with nothing backing
  off automatically. **Mitigation for the demo: rehearse as < 3-minute bursts, phone cool
  at start;** wire the governor (Milestone 8) before any real soak.
- **Venue Wi-Fi hanging the network beats.** Disambiguation and the confirming read both
  hit Claude/Deepgram over saturated MLK venue Wi-Fi. **Script the offline beacon-to-door
  as the climax; make every network beat skippable with a pre-canned fallback line;
  rehearse on a personal hotspot.**

---

## 8. What must be validated with blind co-designers and an O&M instructor before it is trusted

The honest reader and the metric pipeline are the easy half. The hard half is the human in
front of the phone, and the abandonment literature is unforgiving: three of the four
statistical predictors of abandonment are about *process, not capability* — the user's
opinion was not considered in selection, the device was procured too casually, the user's
needs changed. ~75% of electronic mobility aids are abandoned. A technically flawless build
still earns a drawer if it skips co-design and training. So this section is not a closing
caveat; it is a gate the rest of the document sits behind.

**Phase 0, before the beacon grammar is frozen (non-negotiable):**

- **Bring blind travelers and an O&M instructor into the room as co-designers and
  testers**, not as a post-hoc usability check. There is currently no evidence of a single
  blind person in the room; "the team member wearer is the demo" and the team narrating the
  blind experience on a blind person's behalf is the textbook disability-dongle pattern and
  the single strongest abandonment predictor.
- **Resolve the mirrored left/right band bug as blocking** (DepthService.swift:268) before
  the belt carries any approach direction. A 50/50 left-means-right inversion on a
  directional cue can steer a wearer into a hazard.

**Must be tuned with real blind travelers (a sighted-tuned beacon is the feasible-not-useful
trap):**

- Beacon cadence thresholds (what "far / near / here" feel like in motion).
- The "arrived" radius — how close is hand-on-door for this population, not for a sighted
  developer.
- Clock-face vs left/right/ahead default — clock-face is appropriate for the modal older,
  late-blind user but confusing to younger users with no analog-clock fluency. Offer both;
  let the user pick; do not hard-code clock-face only.
- Bone-conduction vs open-ear comfort and traffic-masking, on a real walk near real traffic.

**Must be confronted before any retention claim (the modal-user correction):**

- The modal user is **not** the young, totally-blind power user. ~85% retain usable vision,
  ~60% are 65+, ~1 in 3 has hearing loss, ~36% diabetic (and neuropathy dulls the very
  haptic feedback the belt depends on), phone-averse and stigma-sensitive. A continuous
  audio beacon aimed at this population needs a **co-equal residual-vision visual channel**
  — high-contrast, large-text, on-screen bearing-and-arrival — which the UI does not have
  today. Build it, or honestly narrow the claim to the user actually served.
- **Bundle real training.** Lack of training is a named abandonment predictor and the most
  commonly omitted feature.

**The success metric is retention, not stage wow-factor.** The benchmark for "valuable" is
not "does it work on stage" but "would a blind traveler — including a low-income, partially
sighted, older one — still be using this in six months, on the device and data plan they
actually have." Track 30 / 90 / 365-day retention with a real blind traveler as the primary
KPI. Cool factor can actively *reduce* adoption.

**And the scope boundary that makes the whole thing fundable** (Section 1, restated as a
deployment discipline): door-level precision works only in an environment the team or a
sponsor instruments and surveys. The AprilTag-based sister project "Invisible Map" was
discontinued not for a CV failure but because begging building owners to host markers is
unsustainable emotional labor — placement-permission is the category killer, not the
computer vision. So we **own the environment we paper with markers** (a campus wing, a
clinic, a transit corridor, an airport gate area) and pursue a sponsored/institutional
deployment, the way NaviLens (transit grants), Aira (airport Access Partners), and GoodMaps
(venue B2B) actually get paid — never a retail belt or subscription, which is the
fuse-everything model that killed OrCam. Stating this boundary is a feature, not an
apology.
