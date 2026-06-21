# AI Usage Audit and Expansion Plan

Where AI actually runs in Citrus Squad today, how far it reaches, and the options for expanding it
in a way that fits the product (a haptic navigation belt for blind and low-vision wearers). This is a
handoff: read it before adding any AI feature so the safety boundary and the model choices stay
consistent.

**Owner:** Sam (iOS lane). Pairs with [`PERCEPTION-AVOIDANCE-HANDOFF.md`](PERCEPTION-AVOIDANCE-HANDOFF.md)
(the designed reasoning tier), [`VOICE-COMMANDS.md`](VOICE-COMMANDS.md) (the voice surface), and
[`../docs/14-voice-and-reasoning-plan.md`](../docs/14-voice-and-reasoning-plan.md) (the original design).

## The headline

AI is a thin layer on a deterministic product. The part that actually keeps the wearer safe, the
steering and the collision avoidance, is all hand-tuned logic: LiDAR depth banding, `ObstacleAvoidance`,
`BearingTracker`, the heading resolver and the walk-to-calibrate flow. AI shows up in two narrow
places, and both are deliberately kept off the safety path. That split is the right architecture. The
gap is that the most ambitious AI tier is fully designed on paper and not written yet.

## What runs today, and how far it reaches

### 1. Voice agent (the only AI in the running app)

A Deepgram Voice Agent over one WebSocket, configured in `Sources/Voice/VoiceSession.swift`:

- STT (listen): Deepgram `nova-3`
- Think (LLM): **OpenAI `gpt-4o-mini`**, Deepgram-managed (`VoiceSession.swift:243`)
- TTS (speak): Deepgram `aura-2-thalia-en`

The think model does real work: free speech turns into an intent and a choice of which of the 11
declared functions to call, constrained by a system prompt that forbids claiming a clear path the
sensors did not confirm. But every spoken sentence the wearer hears is a hardcoded Swift string
template grounded in LiDAR and vision (`AppModel.spokenSurroundings`, `spokenPathCheck`, `spokenNextTurn`,
and the rest). So the split is: the LLM owns understanding and routing; the app owns all content and
all safety phrasing.

Note: comments call this "Deepgram-managed Claude" (`VoiceModel.swift:36`, `AppModel.swift:23`), but
the wire config is `gpt-4o-mini`. No Claude runs anywhere in the app today. The Deepgram Haiku attempt
came back `INVALID_SETTINGS: model not available`, so the fallback to the managed OpenAI model shipped.

### 2. Vision (exactly one neural net)

YOLOv8n via CoreML and Vision, on-device, in `Sources/Perception/PersonDetector.swift`, filtered to a
21-class COCO navigation set (`CitrusSquadConfig.visionNavigationClasses`). Everything downstream is
deterministic and explicitly "no AI": depth fusion (`PersonFusion`), the settle and hysteresis gate,
the bearing and looming tracker (`BearingTracker`), the LiDAR banding (`DepthService.bandedNearest`),
and the avoidance logic. ML is the label tier; LiDAR is the safety floor. The open-vocab YOLO-World
swap (poles, trees, bollards) is planned in [`YOLO-WORLD-PLAN.md`](YOLO-WORLD-PLAN.md) but not exported
and not running.

### 3. The Claude reasoning tier (designed, committed in docs, not built)

`AvoidanceAdvisor`, `PerceptionSnapshot`, `SceneCache`, and the draft-and-verify safety pass are all
described in `PERCEPTION-AVOIDANCE-HANDOFF.md` §C and §D and in `docs/14`, but none of it exists in
Swift. There are zero direct Anthropic API calls in the codebase. An `anthropic` key is plumbed through
`Sources/Secrets.swift` and required by `voiceConfigured`, but it is read by nothing.

## Two things to fix regardless of what we build next

- **Naming drift.** The app says "Claude" in comments and provisions an Anthropic key, yet no Claude
  model, hosted or direct, runs anywhere. Correct the comments so the next person is not misled.
- **A live key sits unused in plaintext.** `ios/Local.xcconfig` holds a real, spendable
  `sk-ant-api03-...` key. It is gitignored, so it is not in git, but it does nothing today and is a
  real credential in cleartext. Rotate it, and put real key handling in place (spend-capped, revoked
  after the event) before any Claude path actually starts using it.

## The safety boundary (do not cross it)

Stated consistently across the docs and load-bearing:

- `PERCEPTION-AVOIDANCE-HANDOFF.md:68`: "nothing in the AI path gates the belt."
- `PERCEPTION-AVOIDANCE-HANDOFF.md:86`: "The belt never waits on Claude. Claude only writes audio
  lines and only after the belt has already fired."
- `docs/14`: "The reflex is local and instant. This layer is cloud, conversational, and allowed to be
  slow and to fail. If the voice layer dies mid-walk, the belt keeps guiding."

Every option below stays additive: it can speak, it can describe, it can suggest one dodge, and it is
allowed to be late or to fail. It never blocks, delays, or overrides a belt cue or a stop.

## Model reference (current, from the claude-api skill)

| Model | ID | Input / Output per 1M | Notes |
|---|---|---|---|
| Opus 4.8 | `claude-opus-4-8` | $5 / $25 | 1M context, high-resolution vision (good for small sign text) |
| Sonnet 4.6 | `claude-sonnet-4-6` | $3 / $15 | strong verifier, cheaper than Opus |
| Haiku 4.5 | `claude-haiku-4-5` | $1 / $5 | fastest and cheapest, good for the draft and for cheap vision |

Useful API facts for this product:
- **Vision is multimodal on all of them**; send one base64 RGB frame. Opus 4.7+ does high-res for small
  text.
- **Draft-and-verify**: Haiku drafts the spoken line, Sonnet or Opus verifies it against the snapshot
  and rejects anything the data does not support.
- **Structured outputs** (`output_config.format`) so the verifier returns a parseable
  `{action, side, phrase}` instead of free text.
- **Prompt caching** for the frozen reasoning-contract system prompt (minimum cacheable prefix is 4096
  tokens on Opus 4.8, 2048 on Sonnet and Haiku).
- **Stream** the draft for low time-to-speech.
- **Swift has no official Anthropic SDK**, so these are raw `URLSession` calls to `/v1/messages`, which
  is exactly what `docs/14` specified ("direct Anthropic API calls inside the Swift function").

## Expansion options (prioritized, product-grounded)

### A. Activate the already-designed Claude reasoning tier

Highest return because the scaffold and the docs already exist. Build `PerceptionSnapshot` (the
structured scene: three depth bands, tracked objects with motion, route context, a low/medium/high
confidence), then route `describe_surroundings` and `check_path` through a draft-and-verify pass
instead of the hardcoded strings.

- Models: `claude-haiku-4-5` to draft the line, `claude-sonnet-4-6` to verify against the snapshot.
- Structured output for the verified result; prompt-cache the system prompt; stream the draft.
- Stays additive: the belt already tapped from geometry; this only speaks.

### B. Claude vision (the real product unlock)

The camera is the wearer's eyes, and a fixed 21-class detector cannot read the world. Claude vision
does the things blind navigation actually needs, the ones currently deferred (`read_text`,
`locate_entrance`):

- read a street sign, bus number, store name, building address, posted notice, or menu;
- describe a complex scene ("a cafe entrance about 5 m ahead on your left, two steps up");
- find a crosswalk, door, or entrance.

Constraints: the rear camera is exclusive with the ARKit LiDAR safety reflex, so this is **pull-based**
("look for me", or a voice ask). Grab one frame, send it, return. Never a streaming push that starves
the safety layer. Model: `claude-opus-4-8` for small-text reads, `claude-haiku-4-5` or `sonnet-4-6` for
cheaper scene description.

### C. Give the voice agent a real brain, and fix the drift

Move the think model toward Claude. At minimum, add the Claude draft-and-verify pass on spoken
navigation lines (the unbuilt evaluator `docs/14` already wanted), so the safety check lives on our
side instead of inside Deepgram's hosted OpenAI model. Correct the comments and the key handling in the
same pass.

### D. Net-new wearer features built on B and C (all off the safety path)

- Landmark guidance ("turn at the coffee shop") fusing vision with Maps.
- Traffic-light and crosswalk-state readout from vision.
- The proactive avoidance advisor (the designed D1: threat to snapshot to one verified spoken line).
- Conversational trip memory ("what did I just pass").

### E. On-device ML expansion (AI, not reasoning)

Finish the planned YOLO-World open-vocab swap so the early-warning tier names poles, trees, and
bollards. Already on the roadmap in `YOLO-WORLD-PLAN.md`; listed here for completeness.

## Guardrails for all of it

- Additive only: never gate a belt cue or a stop.
- Respect camera and LiDAR exclusivity: vision is pull-based, one frame at a time.
- Plan for latency and the demo network: `SceneCache` plus a scouted route, pre-warm the connection,
  cache common lines.
- Spend-capped keys, rotated after the event. Fix the exposed key first.

## Where to start

For the demo, the highest wow-per-risk is **B plus A together**: a voice-triggered "what's around me /
read that sign" that grabs a frame, asks Claude vision, and speaks a verified line. It is impossible
with the current stack, it makes the blind-navigation story tangible, and it is entirely off the safety
path so it cannot break the belt.

Suggested first slice, flag-gated and isolated so it touches no safety code:
1. `Sources/Perception/PerceptionSnapshot.swift` (the structured scene value type plus an XML
   serializer for the model context).
2. A pull-based Claude path (`URLSession` to `/v1/messages`): Haiku draft, Sonnet verify, structured
   output, one base64 frame for the vision case.
3. Wire it to a voice command (`describe_surroundings` / a new `read_sign`) and to a manual button in
   the demo HUD.

## File map of what exists vs what to add

| File | State |
|---|---|
| `Sources/Voice/VoiceSession.swift` | Built. Deepgram agent; think = `gpt-4o-mini`. Candidate for the Claude verify pass (C). |
| `Sources/Voice/VoiceCommand.swift` | Built. 11 functions; `read_text` / `locate_entrance` deliberately absent (camera exclusivity). |
| `Sources/Perception/PersonDetector.swift` | Built. The one neural net (YOLOv8n). |
| `Sources/Secrets.swift` | Built. Reads the Anthropic key from Info.plist; currently unused. |
| `Sources/Perception/PerceptionSnapshot.swift` | To add (A). The structured scene the Claude tier reasons over. |
| `Sources/Perception/SceneCache.swift` | To add (A/D). Loosely-keyed cache for zero-latency demo lines. |
| `Sources/Perception/AvoidanceAdvisor.swift` | To add (D). Threat to snapshot to verified spoken line. |
| A Claude client (e.g. `Sources/AI/ClaudeClient.swift`) | To add (A/B/C). `URLSession` to `/v1/messages`; draft + verify + vision. |

When work lands, update [`../STATUS.md`](../STATUS.md) and move items between planned and built here.
