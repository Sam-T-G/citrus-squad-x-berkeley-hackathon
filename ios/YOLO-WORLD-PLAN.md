# YOLO-World Plan — open-vocabulary detection on-device, gated

> The committed end-to-end plan (detection through AI avoidance) now lives in
> [`PERCEPTION-AVOIDANCE-HANDOFF.md`](PERCEPTION-AVOIDANCE-HANDOFF.md). This doc stays as the model
> export recipe and the thermal go/no-go gates it references.


Whether and how we swap the closed-set YOLOv8n person tier for an open-vocabulary YOLO-World
model so the belt can name street infrastructure (poles, bollards, trash cans, parking meters)
that COCO's 80 classes miss. Read [`CV-PORT-PLAN.md`](CV-PORT-PLAN.md), [`../STATUS.md`](../STATUS.md),
and the CV model research in [`../HANDOFF.md`](../HANDOFF.md) (Cole's "CV model landscape" and
"YOLO-World implementation pipeline" sections) first. This plan decides the go/no-go and sequences
the work; Cole already documented the Python export steps, so this does not repeat them.

**Owner:** Sam (iOS lane) for the Swift side. Cole owns the CoreML export and the webcam validation.
This plan stays inside `ios/` plus a one-time export Cole runs.

## Verdict up front

Technically feasible. Not a base-demo item. Treat it as a hard-timeboxed stretch behind a feature
flag, with YOLOv8n always live as the fallback. Cole's own research lands in the same place: keep
v8n for COCO movers, cover the street-infrastructure gap with Claude Vision plus scout-and-cache,
and only prototype YOLO-World if there is a spare hour late in the window.

The reason to keep it dark by default is not that it cannot work. It is that the two things it
depends on are both unproven right now: the thermal soak (the #1 stated demo risk) has not run even
on the lighter v8n, and there is no YOLO-World-nano, so the smallest variant is roughly four times
the parameters of v8n. Putting a hotter model on the critical path before the cooler one is proven
is backwards. So this plan gates the swap behind proof, not hope.

## What it actually buys us

The gap is vocabulary, not accuracy. YOLOv8n finds people, bikes, cars, and dogs well, and LiDAR
fires the belt tap regardless of class. What v8n cannot name is exactly what a blind pedestrian
walks into: poles, bollards, trash cans, parking meters, street lights, construction barriers.
YOLO-World takes a text vocabulary at export time, so we can ask for those class names without
retraining. After export the text encoder is gone and it runs as a wider closed-vocab detector,
which is what keeps it fast enough to even consider on the phone.

So the win is a spoken label on the audio tier: "trash can on your left" instead of a tap with no
context. The belt behavior does not change. The tap already fires from LiDAR distance.

## Go / no-go gates (all three before spending the timebox)

Do not start the swap until every one of these is green. If any is red, ship v8n plus Claude Vision
and leave YOLO-World for post-hack.

1. **Thermal soak passes on v8n.** The 10-minute run in `docs/12` §6 holds out of `.serious`
   thermal state with the current person tier live. If v8n already runs hot, a heavier model is off
   the table.
2. **Test CoreML export succeeds on the Mac.** Cole runs the export from `../HANDOFF.md`
   "YOLO-World implementation pipeline" Step 1 and confirms `yolov8s-worldv2.mlpackage` comes out as
   a real NMS pipeline (not raw tensors), validated against `cv/webcam_test.py`. RepVL-PAN does not
   always convert clean; this is the single largest unknown and it is Cole's to clear before any
   Swift work starts.
3. **The person tier is proven live on-device.** `PersonDetector` fires a clean `0x10` cue on the
   correct side from the bundled v8n, with the `.right` orientation calibration confirmed (the open
   item in `CV-PORT-PLAN.md`). We do not generalize a tier that is not yet working in its simple
   form.

## Resolve this first: two CV implementations exist

There are two parallel detector implementations and they are not the same shape. The swap doc Cole
wrote assumes the wrong one for our active branch.

- **`sam/ios-app-base` (production, the demo branch):** `Perception/PersonDetector.swift`. **No longer
  person-only as of commit `3c83f75`.** The hardcoded `isPerson(_:)` is replaced with
  `navigationLabel(_:)`, a class-set filter against `CitrusSquadConfig.visionNavigationClasses` (21
  COCO classes, in lockstep with `cv/detection.py`), and `PersonDetection` carries the matched label.
  This is path A's Swift generalization (step 3 below) already landed against the bundled v8n. What
  remains for YOLO-World is the heavier model export and the model-selection flag, not the filter.
- **`cole/computer-vision` (not merged):** `Perception/ObjectDetectionService.swift`. Multi-class,
  with a `navigationClasses: Set<String>` constant, plus `MotionTracker` and `CollisionPredictor`.

Cole's "Step 3 — Swift (one constant changes)" in `../HANDOFF.md` edits
`ObjectDetectionService.navigationClasses`. That constant does not exist on the demo branch. So on
our branch the Swift change is not one line. We either:

- **(A) Generalize `PersonDetector` in place.** Replace the hardcoded `isPerson` filter with a
  `navigationClasses: Set<String>` filter, keep everything else (fusion, gate, orientation) intact.
  Smallest, safest change. Recommended. The cue stays "nearest in-range thing" instead of "nearest
  person"; the gate and intensity math do not care about the label.
- **(B) Merge Cole's `ObjectDetectionService` onto the demo branch.** Brings `MotionTracker` and
  `CollisionPredictor` too. More capability, more surface to re-validate under Swift 6 strict
  concurrency, more thermal cost from the motion tracker. Do not take this on during the window just
  to get YOLO-World; decide it on its own merits separately.

This plan assumes path **(A)**.

## Implementation, sequenced

Each step has an acceptance bar. The model swap is steps 1 and 2; the Swift generalization is 3 and
4; everything else is discipline already built for v8n that carries over.

### Step 1 — Export (Cole, ~1 hr clean, 2–3 hr if fiddly)
Run the export in `../HANDOFF.md` Step 1: `YOLOWorld('yolov8s-worldv2.pt')`, `set_classes([...])`
with the navigation vocabulary, `export(format='coreml', nms=True)`. `nms=True` is required, same as
v8n; without it Vision gets raw tensors and detects nothing. Validate the export against
`cv/webcam_test.py` before handing it over. Try class-name synonyms ("trash can" vs "trashcan");
the learned text embeddings are sensitive to wording.

**Acceptance:** `yolov8s-worldv2.mlpackage` loads in `webcam_test.py` and boxes the prompted street
classes on the laptop. This is gate 2 above.

### Step 2 — Bundle alongside v8n, do not replace it (Sam)
Drop `yolov8s-worldv2.mlpackage` into `ios/Sources/Resources/` next to `yolov8n.mlpackage`. Keep
both bundled so the flag can pick at launch and the fallback is instant. Reference it in
`Project.yml`, run `xcodegen generate`.

**Acceptance:** project builds with both models bundled; the app size bump is acceptable for a debug
build on the demo phone.

### Step 3 — Model selection flag + generalized filter (Sam)
**Status: the filter half is done (commit `3c83f75`).** `CitrusSquadConfig.visionNavigationClasses`
exists (21 classes, default-on, not gated behind a flag since it costs nothing on v8n), `isPerson` is
now `navigationLabel`, and `PersonDetection` carries `label`. What is left here is only the
`visionModelName` selector below, which the world-model swap needs.
- Add `CitrusSquadConfig.visionModelName` (default `"yolov8n"`) and a
  `visionNavigationClasses: Set<String>` (default `["person"]`, the full nav vocabulary when the
  flag flips). One place to change.
- In `PersonDetector.loadModelIfNeeded`, load `CitrusSquadConfig.visionModelName` instead of the
  hardcoded `"yolov8n"` resource name.
- Replace `isPerson(_:)` with a class-set filter against `visionNavigationClasses`. Carry the label
  through `PersonDetection` (add `var label: String`) so the audio tier and the diagnostics console
  can read it. The fusion math, the `decide` gate, the orientation map, and the intensity grading
  all stay exactly as they are; they key on distance and side, not on the class.

**Acceptance:** with the flag on and the world model bundled, the diagnostics console shows boxes
labeled `pole`, `trash can`, etc.; with the flag off it behaves identically to today (person only,
v8n). Off is the demo default.

### Step 4 — Thermal governance for the heavier model (Sam)
The world model is roughly 4× v8n's parameters, so the throttle and the degrade ladder matter more,
not less.

- Start at a lower detection rate. `CitrusSquadConfig.visionMaxHz` is 4.0 today; drop the world
  model to 2.0–3.0 Hz and measure. The decide loop stays at 10 Hz; detection does not need to keep
  up. The throttle already lives in `PersonDetector.process` via `throttleInterval`.
- The existing thermal gate (`AppModel` flips `depth.visionEnabled` off at `.serious`) already
  protects the belt: at thermal pressure the camera tier drops and LiDAR proximity carries the
  safety story. Confirm it trips at the same threshold with the heavier model in the loop.

**Acceptance:** a 10-minute run with the world model live holds out of `.serious`, or the degrade
ladder drops it cleanly to LiDAR-only without the belt going dark. If it cannot hold even at
2 Hz, that is the signal to keep it as a scout-mode-only tool and not run it live.

## Timebox and cut criteria

Cole's estimate is 1 hour for a clean export and Swift swap, 2–3 hours if the CoreML export fights
back. That is the whole budget. The export (gate 2) is the make-or-break; if it does not produce a
working NMS pipeline within that window, stop and fall back. Swift steps 3 and 4 are small and
predictable once a good `.mlpackage` exists.

Cut to v8n plus Claude Vision if any of: the export will not convert, the model runs hot at 2 Hz,
or the demo route's objects are already covered by the scout-and-cache labels. The base demo never
depended on this; it stays whole without it.

## What this does not replace

YOLO-World does not remove the need for Claude Vision. It widens the on-device vocabulary to a fixed
prompted list, but the list is frozen at export time and cannot grow mid-demo. Claude Vision stays
the open-ended gap-filler for anything off the prompted list, and the scout-and-cache strategy in
`../HANDOFF.md` is still the honest zero-latency demo story. If the export does not land, that path
alone already covers the street-infrastructure labels for a controlled demo loop.

The real post-hack target for this gap is on-device Mapillary Vistas segmentation (124 classes built
for exactly this domain), not YOLO-World. YOLO-World is the Saturday-night experiment; Mapillary is
the thing to build properly afterward.

## Files this touches (path A)

| File | Change |
| --- | --- |
| `ios/Sources/Resources/yolov8s-worldv2.mlpackage` | New. Cole's export, bundled beside v8n. |
| `ios/Sources/CitrusSquadConfig.swift` | Add `visionModelName` + `visionNavigationClasses`; lower `visionMaxHz` for the world model. |
| `ios/Sources/Perception/PersonDetector.swift` | Load the configured model name; swap `isPerson` for a class-set filter; carry `label` on `PersonDetection`. |
| `ios/Sources/Perception/PersonFusion.swift` | No change. Distance and quadrant math is label-agnostic. |
| `ios/Project.yml` | Bundle the second model. Regenerate after. |
| `ios/Sources/UI/...` (diagnostics) | Show the detected label so the pitch can narrate it. |

When this lands or is cut, update `../STATUS.md`: move the item between in-flight and done (or note
the cut and why), bump the latest commit, add a session-log line.
