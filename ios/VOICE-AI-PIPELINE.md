# Voice + AI Pipeline

How a spoken request becomes a spoken answer, where the time goes, and the rule that decides whether a
request is answered instantly on-device, by Deepgram alone, or by Claude. Read this before changing
anything in the voice path or the `AI/` tier.

**Owner:** Sam (iOS lane). Pairs with [`VOICE-COMMANDS.md`](VOICE-COMMANDS.md) (the function surface),
[`AI-USAGE-AUDIT-AND-EXPANSION.md`](AI-USAGE-AUDIT-AND-EXPANSION.md) (where AI runs and why), and
[`../docs/14-voice-and-reasoning-plan.md`](../docs/14-voice-and-reasoning-plan.md) (the original design).

## The one rule

Deepgram is the voice for everything. Claude is reached only where judgment or vision earns its
latency. A request is answered at the lowest tier that can answer it correctly, and it never waits on a
model it does not need.

That is the whole design. The rest of this doc is the stages, the tiers each request falls into, the
reasons, and the scenarios.

## The stages, and where time goes

Every spoken request runs the same loop. Deepgram owns the ears, the turn-taking, and the mouth; the
app owns the functions; Claude is an optional step inside one function.

```
wearer speaks
  -> Deepgram STT (nova-3)                    streaming partials, ~100-300 ms to first text
  -> Deepgram end-of-turn (its own VAD)        fires on a pause, ~200-800 ms after they stop
  -> Deepgram think (gpt-4o-mini) picks a fn   ~300-700 ms
  -> FunctionCallRequest over the socket
       -> VoiceSession runs the Swift fn        the tier decides what happens here (below)
       -> FunctionCallResponse: one sentence
  -> Deepgram think speaks the sentence back   verbatim instruction keeps this ~150-400 ms
  -> Deepgram TTS (aura-2)                      first audio ~150-400 ms
wearer hears the answer
```

Two things fall out of this picture and drive every decision below.

**There is a fixed conversation floor on every answer, Claude or not.** End-of-turn plus two think
passes plus text-to-speech is roughly **0.9 to 2.0 seconds** before the function's own work even
counts. That floor is Deepgram's, and it applies to "stop" exactly as much as to "read that sign." So
the lowest-latency thing we can do for a simple command is keep its function instant and let Deepgram
be Deepgram. Reaching for Claude on a simple command does not make it a little slower, it stacks a
whole second-plus on top of a floor we cannot remove.

**The think model speaks the function's result.** After the function returns, gpt-4o-mini generates the
spoken turn from the returned content. Left alone it paraphrases, which both adds latency and can
re-introduce a claim we carefully removed. The system prompt now tells it to **speak the returned
sentence verbatim**. That keeps a sensor-grounded or guard-checked line intact, and it makes the second
think pass a cheap relay instead of a rewrite.

## The tiers

Each function is classified by the lowest tier that answers it correctly. The classification lives in
`AppModel.handleVoice`; this table is the contract.

| Tier | What runs | Added latency over the floor | Functions |
|---|---|---|---|
| **0 — instant, on-device** | Pure local logic or state read. No model, no network. | ~0 ms | `stop`, `route_status`, `next_turn`, `trip_summary`, `check_path`, `recalibrate`, `connect_belt`, `disconnect_belt` |
| **1 — small local network** | One Apple/Maps call. No Claude. | ~0.3-2 s | `where_am_i` (reverse geocode), `set_destination` (place search + route) |
| **2 — Claude judgment** | One fast-model call over the scene snapshot, plus a local guard. | ~0.5-1.2 s, or 0 when skipped | `describe_surroundings` |
| **3 — Claude vision** | One frame to the vision model. | ~1.2-3 s | `read_sign`, `locate_entrance` |

### Why `check_path` is Tier 0, not Claude

`check_path` is the collision-relevant query, so it must be the fastest and the safest. It already is:
`ObstacleAvoidance.decide` computes the open side from the three LiDAR bands as a pure function, and
`spokenPathCheck` turns that into a grounded sentence that already names the safe direction. Claude
cannot improve the safety call (the geometry is exact), and routing it through a model would add a
second of latency and a chance to get the side wrong. So `check_path` stays on-device and instant. This
was the one thing the first cut got backwards, and it is fixed.

### Why `describe_surroundings` is Tier 2, and how it stays honest and fast

Describing a scene is judgment: which of several things to mention, and how to say it for a listener.
That is where Claude earns a call. Three gates keep it fast and safe:

1. **Skip when there is nothing to judge.** If the snapshot is not informative (no tracked object and
   no LiDAR return inside the belt range), the grounded "your path ahead is clear" line is already the
   whole answer, so the model call is skipped entirely. The common open-sidewalk case pays nothing.
2. **One call, under a tight timeout.** When there is something to describe, the fast model drafts one
   sentence over the snapshot XML under a 2.5 s ceiling. The Deepgram turn is held open while this
   runs, so the budget is deliberately short; past it, the grounded line is spoken instead.
3. **A local guard instead of a second model call.** The first cut verified the draft with a second,
   stricter model call, which doubled the latency. That is replaced by `SpokenLineGuard`, a local
   instant check that refuses one specific dangerous hallucination: a "clear path" claim when the LiDAR
   says something is close. Anything it rejects falls back to the grounded line. The one error that can
   hurt the wearer is caught for free; phrasing and labels are left to the snapshot's grounding.

### Why the vision reads are Tier 3 and latency-tolerant

`read_sign` and `locate_entrance` are pull-based: the wearer deliberately asks the device to look, and
waits a beat for it, the way a sighted person pauses to read a sign. They grab one frame from the
already-running ARSession (no second camera, so no contention with the LiDAR reflex), send it to the
vision model under a 5 s ceiling, and speak the read. A failure or a blank read returns a plain spoken
reason, never a guess. The `.thinking` chime plays while they run, so the wait is not silent.

## What keeps it fast and safe (the levers)

- **Verbatim relay.** The think model speaks the function's sentence word for word. Preserves grounding,
  shortens the second think pass.
- **Instant fallback everywhere.** Every Tier 2/3 path has a sensor-grounded string it speaks on any
  miss (no key, timeout, error, refusal, rejected line). Deepgram is the voice regardless; Claude only
  upgrades the line when it comes back in time and clean.
- **Skip-when-trivial.** Describe pays for Claude only when the scene has something to describe.
- **Local guard, not a second call.** `SpokenLineGuard` replaces a model round trip with an on-device
  check for the one dangerous claim.
- **Tight per-tier timeouts.** 2.5 s for describe, 5 s for a vision read, 6 s for the manual HUD
  buttons. The live voice budgets are short so Deepgram is never left holding a dead turn.
- **Connection pre-warm.** One tiny throwaway request at launch warms the TLS connection, so the first
  real read on stage does not pay the handshake.
- **Nothing on the safety path.** No Claude call touches the 10 Hz decide loop or the 100 ms heartbeat.
  The belt is driven by LiDAR geometry and never waits on any of this.

## Scenarios

Each row is a real wearer request traced through the pipeline. "Added" is on top of the ~0.9-2.0 s
Deepgram floor.

| The wearer says | Function | Tier | Added | What happens |
|---|---|---|---|---|
| "Stop." | `stop` | 0 | ~0 | Clears guidance, speaks "Stopped." The brake: always instant. |
| "How far to the next turn?" | `route_status` | 0 | ~0 | Reads `RouteEngine`, speaks the distance and turns left. |
| "Which way do I turn?" | `next_turn` | 0 | ~0 | Speaks the next maneuver in feet from the same cue the belt follows. |
| "How much further?" | `trip_summary` | 0 | ~0 | Distance and rough walking time to the destination. |
| "Is the way clear?" / "What's in front of me?" | `check_path` | 0 | ~0 | On-device avoidance: "Heads up, a person on your right about 8 feet. The left side is open, ease left." Instant and safe. |
| "Where am I?" | `where_am_i` | 1 | ~0.3-1 s | Reverse-geocodes the GPS fix: "You are near Moffitt Library." |
| "Take me to the coffee shop." | `set_destination` | 1 | ~0.5-2 s | Resolves the place, builds a route, starts the live walk. One clarifying question if ambiguous. |
| "What's around me?" (open sidewalk) | `describe_surroundings` | 2 | ~0 | Snapshot not informative: skips Claude, speaks the grounded clear line instantly. |
| "What's around me?" (something ahead) | `describe_surroundings` | 2 | ~0.5-1.2 s | Fast model drafts over the snapshot, local guard checks it, speaks it; grounded fallback on any miss. |
| "Read that sign." / "What does that say?" | `read_sign` | 3 | ~1.2-3 s | Grabs one frame, vision model reads the text, speaks it. Chime plays while it works. |
| "Where's the entrance?" | `locate_entrance` | 3 | ~1.2-3 s | One frame, vision model finds a door and says roughly where. |
| "Recalibrate." | `recalibrate` | 0 | ~0 | Restarts the walk-to-calibrate offset capture. |
| Asks a question mid-turn while the belt is tapping | any | any | per tier | The haptic leads (it is the navigation channel); the spoken answer rides alongside. |
| "Read that sign" with the camera off | `read_sign` | 3 | ~0 | No frame: "Turn the camera on and point it at the text." No guess. |
| No network, "what's around me?" | `describe_surroundings` | 2 | ~0 | Claude call fails fast; speaks the grounded line. Belt and the on-device tiers are unaffected. |
| Claude slow past the budget | 2 or 3 | 2/3 | budget cap | The timeout fires; speaks the grounded line. Deepgram never holds a dead turn. |
| Wearer cuts the device off mid-describe | any | any | n/a | Deepgram barge-in stops the TTS; the wearer's new turn takes over. |
| Deepgram down or mic denied | n/a | n/a | n/a | Voice goes unavailable once, spoken at launch. The belt, the route, and the screen all keep working. |

## Tools added this pass

- `Sources/AI/ClaudeClient.swift` — per-call `timeout`, and `prewarm()` for the launch TLS warm.
- `Sources/Perception/SpokenLineGuard.swift` — the local, instant clear-path consistency check that
  replaces the second model call on the voice path.
- `Sources/Perception/PerceptionSnapshot.swift` — `isInformative` (skip-when-trivial) and
  `hasCloseObstacle` (what the guard reads).
- `Sources/CitrusSquadConfig.swift` — `claudeVoiceTimeoutSeconds` (2.5), `claudeVisionTimeoutSeconds`
  (5), kept separate from the 6 s HUD default.
- `Sources/Voice/VoiceCommand.swift` — `locate_entrance` is now served, not stubbed.
- `Sources/Voice/VoiceSession.swift` — the system prompt now enforces verbatim relay and lists the
  full function set including the camera reads.

## Open tunables and next steps

- **Endpointing.** End-of-turn detection is the largest single piece of the Deepgram floor. Deepgram's
  default VAD is used now; a tighter end-of-turn setting would shave the floor on short commands at the
  risk of clipping a slow speaker. Tune against the demo venue, do not guess it blind.
- **Spoken filler for Tier 3.** The `.thinking` chime covers the vision wait today. A short spoken
  "looking now" would feel better, but needs a second TTS turn; only worth it if the chime tests poorly.
- **The snapshot is thin until YOLO-World.** Describe's judgment value grows a lot once the per-band
  object lists fill in (handoff Part B/C). Today the snapshot carries the bands plus one fused hazard,
  so describe is mostly nicer phrasing of the same data. The tier and the gates do not change when the
  richer data lands; only the value of the call goes up.
- **`SceneCache`.** A loosely-keyed cache of recent verified lines (per `docs/14`) would make a scouted
  demo route speak instantly with no live call. Not built yet; the pre-warm covers the first-call case.

When work lands here, update [`../STATUS.md`](../STATUS.md) and this table.
