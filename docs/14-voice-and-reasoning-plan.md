# 14 — Voice and reasoning plan (Deepgram + Claude)

The build plan for the talk and think tiers from [`13-sponsor-implementation-ideas.md`](13-sponsor-implementation-ideas.md). This is the layer that lets a blind wearer speak to WAND and hear short, verified answers, with every spoken request mapped to a real device action. It is a gameplan and a blindspot list, not a final spec. Lock the open questions before writing the WebSocket code.

Pairs with:

- [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md) — the module contract. A new `VoiceSession` obeys it.
- [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md) — owns the perception snapshot this layer reads.
- [`13-sponsor-implementation-ideas.md`](13-sponsor-implementation-ideas.md) — why this design uses each product's headline strength.

## What we are building

A push-to-talk voice interface where the wearer speaks, WAND acts, and WAND speaks back only when asked. Two sponsor products, used for what they are best at:

- **Deepgram Voice Agent API** is the ears and mouth: speech-to-text, text-to-speech, turn-taking, and barge-in in one real-time stream.
- **Claude** is the brain: it runs as the Voice Agent's LLM and decides which device function to call, and it runs a second, stricter pass to verify anything safety-relevant before it is spoken.

This satisfies the Deepgram requirement (we use a Deepgram product as the core interface) and the Anthropic angle (Claude as a tool-using agent with a verification step) in one path.

## What we are not building yet

Camera vision tools (`read_text`, `locate_entrance`) depend on on-device vision, which is a stretch in [`05-vision-tier.md`](05-vision-tier.md). They ship as stubs that say "I cannot do that yet" until the vision tier lands. The Fetch transactional tier is a separate doc and a separate owner. Continuous turn-by-turn stays on the belt and is untouched by this layer.

## As-built (verified on device, 2026-06-21)

The sections below this one are the original design intent. This section is what actually shipped
after a full on-device bring-up at the hackathon. Where the two disagree, this section wins.

**Status: working end to end on the demo phone.** Tap to talk, speak a command, the agent
transcribes it, calls an on-device function, and speaks the answer out of the loud speaker.
Speech-to-text, function calling, live location, and the navigation link are all live.

**Think tier is Deepgram-managed `gpt-4o-mini`, not Claude.** The plan ran Claude Haiku as the agent
LLM. On the account in use, `claude-4-5-haiku-latest` came back `INVALID_SETTINGS: model not
available`, so the think tier is the Deepgram-managed OpenAI model `gpt-4o-mini` (`provider.type`
`open_ai`), which needs no key of ours. Claude is reserved for the V3 on-device evaluator with our
own Anthropic key, which is the cleaner Anthropic integration anyway. Listen is `deepgram` `nova-3`;
speak is `deepgram` `aura-2-thalia-en`.

**Settings-schema corrections the plan got wrong.**

- A function is client-side by *omitting* its `endpoint`. There is no `client_side` flag; sending
  one fails the whole Settings message with `UNPARSABLE_CLIENT_MESSAGE`.
- Endpoint `wss://agent.deepgram.com/v1/agent/converse`, header `Authorization: Token <key>`. Correct.
- Verified server events: `Welcome`, `SettingsApplied`, `ConversationText` (role user / assistant),
  `FunctionCallRequest` (a `functions` array, each with `id`, `name`, and `arguments` as a JSON
  string), `UserStartedSpeaking`, `AgentAudioDone`, `Error`, `History`. We answer a call with a
  `FunctionCallResponse` carrying `id`, `name`, `content`.

**Turn model is continuous streaming, not stop-audio-on-release.** The plan's `finishTurn` stopped
the mic on release; Deepgram reads that as `CLIENT_MESSAGE_TIMEOUT` ("did not receive audio"). The
Voice Agent wants a continuous stream and finalizes the turn itself with its own voice-activity
detection when the speaker pauses. So the mic streams from start to stop, and the agent answers on a
pause. `finishTurn` was removed.

**Interaction: tap-to-toggle on screen, or press-and-hold a volume button.** Tap the on-screen
control to start a turn, or press and hold a hardware volume button to start it by feel. Speak, then
wait; the agent answers on a pause. Trigger again while active to cancel. Labels cycle Tap to talk /
Connecting / Listening / Thinking / Speaking.

**Hardware trigger (`VolumeButtonTrigger`).** iOS exposes no hook for the side or Action button, so
the volume buttons are the only physical option. It observes `AVAudioSession.outputVolume` via KVO. A
held button auto-repeats, so a *burst* of volume changes fires the agent once; a single tap is one
change and is ignored, which keeps an accidental volume tap from triggering. The press is absorbed:
system volume is parked back to mid-level through a hidden `MPVolumeView` slider so it never drifts to
a rail and stops the auto-repeat, and that off-screen view suppresses the volume HUD. Hosted as a
hidden background on the Operate screen. The auto-repeat timing is OS-specific and tunable
(`pressesToFire`, `releaseMilliseconds`).

**Audio cues, and why the ready cue is synthesized.** `AudioServicesPlaySystemSound` is a UI sound the
ringer switch silences and an active record session can mute, so it is unreliable as feedback during a
voice turn (the agent's TTS reply still plays because it is media, not a UI sound). The ready
confirmation therefore plays through the media route, like the TTS: `ChimePlayer` synthesizes a soft
rising C5 -> G5 fifth over a warm low C with a few harmonics, heard at speaker volume even on silent,
paired with the success haptic. A light haptic ticks when the hold first registers. The cues map to
state: `voiceActivating` on `connecting`, `voiceReady` (the chime) on `listening`, `voiceProcessing`
on `thinking`.

**Echo is handled in software.** With a plain audio mode there is no hardware echo cancellation, so
the agent could transcribe its own voice. An `agentSpeaking` flag mutes the outgoing mic from the
first TTS chunk until `AgentAudioDone`, which stops the loop.

**Audio routes to the loud speaker.** `.voiceChat` / `.videoChat` modes make iOS treat the session
as a phone call and route to the quiet earpiece. The session uses plain `.default` mode with
`.defaultToSpeaker` and an explicit `overrideOutputAudioPort(.speaker)`. Input is 16 kHz linear16,
output 24 kHz linear16.

**Functions as shipped:** `set_destination`, `route_status`, `where_am_i` (new), `describe_surroundings`,
`recalibrate`, `stop`. `read_text` and `locate_entrance` stay out, because the camera is exclusive
with the ARKit LiDAR safety reflex.

**`where_am_i`** reverse-geocodes the live GPS fix (CLGeocoder) to a spoken place, for example "You
are near University of California, Berkeley." Location starts at launch so a fix is ready.

**`set_destination` is wired to real navigation.** It resolves the spoken place with MKLocalSearch
(presets first, duplicate chain results collapsed by name), builds a real route to those coordinates
(Google Directions when a Maps key is set, otherwise a direct origin-to-destination line), and drives
it off the wearer's live GPS and compass (`startLiveWalk`), not the simulator. The belt and the map
go to the actual place, based on where the wearer really is.

**Milestones V0 through V4 are done on device.** V0 mic-to-transcript, V1 a function round-trip, V2 a
spoken destination starting a live route, V3 surroundings narration (LiDAR-grounded; the Claude
draft-and-verify pass is still a follow-up), V4 tap-to-toggle with the cancel path and the audio
cues. V5 (camera tools) stays out by design.

**Blindspots resolved this pass:** the earpiece audio routing, the echo loop, the place-name gap, and
the turn timeout. Still open: the Claude draft-and-verify evaluator for safety-relevant narration
(the depth of V3), calibration-on-start for the live walk so body heading is right at the chest
mount, and pre-warming the socket so the first tap connects instantly.

## The one hard rule, restated

Nothing here touches the LiDAR obstacle reflex in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md). The reflex is local and instant. This layer is cloud, conversational, and allowed to be slow and to fail. If the voice layer dies mid-walk, the belt keeps guiding and the reflex keeps firing.

## Architecture

### The chosen path

Deepgram Voice Agent API with client-side function calling, Claude as the agent LLM.

```
button press -> mic open
  -> Deepgram Voice Agent (cloud)        STT, turn-taking, barge-in
     -> Claude (agent LLM, fast model)   picks a function from the request
  -> FunctionCallRequest over WebSocket  client_side = true
     -> VoiceSession runs the Swift fn   on-device, real WAND state
        -> for safety lines, the fn runs the drafter + evaluator itself
     -> FunctionCallResponse             the verified result string
  -> Deepgram TTS                        speaks the result
```

Why this shape: the Voice Agent gives barge-in and turn-taking for free, which is the whole reason voice is right for a blind user. Function calling with `client_side: true` means the function runs in our Swift code against live WAND state, so the agent can read perception and drive routing without us hosting a server.

### Where the evaluator lives

Claude Haiku is the conversational brain inside the Voice Agent, tuned for speed. The safety verification does not belong there, because we do not control that loop tightly enough. Instead, the safety-relevant functions run the drafter and evaluator themselves, as direct Anthropic API calls inside the Swift function, and return only the verified line. So `describe_surroundings()` internally drafts a sentence with Haiku, verifies it against the raw perception data with Sonnet, and hands the Voice Agent a line that is already safe to speak. The conversation stays snappy and the safety check stays on our side.

### The fallback path

If the Voice Agent's bring-your-own-LLM or client-side function calling proves flaky during bring-up, fall back to Deepgram streaming speech-to-text plus Deepgram text-to-speech as two separate products, with our own Claude tool-use loop in between. More glue code, full control, and it still qualifies for Deepgram because it uses two of their products. Decide this at milestone V1, not later.

### Concurrency

`VoiceSession` is its own actor that owns the WebSocket and the audio. It never runs on the 1 Hz decision loop or the 10 Hz heartbeat from [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md). It reads `RouteEngine` state through a snapshot and stages destination changes the same way the decision loop stages cues, through the existing actor boundary. A slow Claude call cannot stall the heartbeat, by construction.

## The function contract

These are the client-side functions exposed to the agent. Each one names what executes, the latency we can live with, and what happens on failure. Failure always degrades to speech the wearer can act on, never a crash or silence.

| Function | Example request | Executes | Returns | Budget | On failure |
|---|---|---|---|---|---|
| `set_destination(place)` | "take me to Moffitt Library" | resolve the place, start `RouteEngine` | "Heading to Moffitt Library" | 1 to 2 s | "I could not find that place, say it again" |
| `describe_surroundings()` | "what is around me" | perception snapshot, draft, verify | one prioritized sentence | 1 to 3 s | "I cannot read the surroundings right now" |
| `route_status()` | "how far", "where am I" | read `RouteEngine` state | distance and next turn | under 0.5 s | "navigation is not running" |
| `recalibrate()` | "recalibrate" | trigger the heading offset capture | "Recalibrated, face forward" | under 0.5 s | "hold still and try again" |
| `stop()` | "stop", "cancel" | clear the staged cue, end guidance | "Stopped" | under 0.5 s | always succeeds |
| `locate_entrance()` | "where is the entrance" | camera frame, Claude vision | direction to the door | 2 to 3 s | stub: "I cannot do that yet" |
| `read_text()` | "read that sign" | camera frame, Claude vision | the text | 2 to 3 s | stub: "I cannot do that yet" |

Design notes that are easy to get wrong:

- **`set_destination` confirms, it does not assume.** When the place is ambiguous, the function returns a clarifying question and the agent asks it. One question, then proceed. This is the destination-understanding job from doc 13.
- **`describe_surroundings` is pull, never push.** The device narrates only when this is called. It does not narrate on a timer. Truth 6.
- **`stop` is sacred.** It must always work and always be fast, because it is the wearer's brake.

## The perception snapshot

`describe_surroundings()` and the evaluator both read one structured snapshot, owned by the perception tier in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md). It does not exist yet. It is a dependency, called out in the blindspots.

Proposed shape, fed to Claude as XML-structured input per the Anthropic prompt-engineering guidance:

```
snapshot:
  timestamp
  bands:
    left:   { nearest_meters, classes: [person, ...] }
    center: { nearest_meters, classes: [...] }
    right:  { nearest_meters, classes: [...] }
  route:    { next_turn, distance_meters, on_route: true/false }
  confidence: low/medium/high
```

The evaluator's rule: never claim a band is clear unless `nearest_meters` supports it, never name an object the classes list does not contain, and when `confidence` is low, say so rather than guess.

## Interaction model

**Push-to-talk, not always listening.** A noisy venue wrecks open-mic transcription, and an always-open mic is a privacy problem. The wearer holds a button to talk. Open question below: which button, given the wearer cannot see the screen.

**On demand, not chatty.** The belt carries continuous guidance with no words. Voice speaks only in response to a request or to confirm a destination. The ears stay free for the street.

**Barge-in on.** The wearer can cut the device off the instant they have heard enough. The Voice Agent supports this natively, which is half the reason we chose it.

## Latency budget

A realistic on-demand answer:

- Button to first transcript: under 300 ms (Deepgram).
- Claude picks a function: roughly 0.5 to 1 s on the fast model.
- Function runs, including the draft and verify for `describe_surroundings`: 1 to 2 s.
- Text-to-speech first audio: a few hundred ms.

So one to three seconds end to end for a described scene, faster for status. That is fine for a pulled answer. It is not fine for a reflex, which is exactly why crossing and obstacle decisions stay on the haptic and LiDAR side and are never gated on this path.

## Secrets and permissions

### Where the API keys live

Two keys, Deepgram and Anthropic. Neither ever gets committed. The repo rule in `CLAUDE.md` is absolute: load them from an untracked `xcconfig` or build environment, never a committed source file.

The real question is whether the keys ship inside the app or sit behind a server. For one demo phone we own, the answer is in the app. The only thing a server buys is hiding the key from an untrusted client so a stranger cannot extract it and spend our money, and that threat does not exist here. What a server costs is a new live network hop that can fail on stage and a service to babysit, which fights the minimize-failure-points design of the whole base. Three options, in order of fit:

| Option | Effort | Demo risk | When it fits |
|---|---|---|---|
| **A. Keys in the app** | near zero | lowest | one phone we own, rotate after. Our case. |
| **B. Token-mint endpoint** | 30 to 60 min | low | a spare hand who wants it correct cheaply |
| **C. Full proxy of all traffic** | hours | highest | a public app. Not us. |

Default is A. Load from an untracked config, use a spend-capped key, revoke both keys right after judging.

If a teammate wants to do it more correctly for cheap, that is option B, not C. Deepgram's recommended pattern for mobile clients is a short-lived key: a tiny endpoint mints a Deepgram token with a few-seconds TTL, the app opens the Voice Agent socket with that, and the durable key never ships in the binary. Do this for the Deepgram key if someone owns the endpoint, and leave the Anthropic calls direct with a capped key. Avoid C. It is the most infra and the most new failure points for the least demo value.

One stack-specific note. With the Voice Agent's bring-your-own-LLM native Anthropic provider, our Anthropic key is handed to Deepgram as endpoint headers. To avoid giving the key to a third party at all, let the Voice Agent run Deepgram's managed Claude Haiku for the conversation, and keep our own Anthropic key only for the direct drafter and evaluator calls inside `describe_surroundings()`. That keeps the key on a tighter leash than a proxy would.

### Microphone permission

Doc 11 declares Location, Motion, and Camera. It does not declare `NSMicrophoneUsageDescription`. Voice cannot work without it. Add the key and the usage string, and grant it before the demo so the prompt does not surface on stage.

## Failure and degradation

| Failure | What the wearer experiences | What keeps working |
|---|---|---|
| No network | "voice is unavailable" once, then quiet | belt guidance, the replay route, the reflex |
| Deepgram down | same as no network | everything except voice |
| Claude slow or errors | "give me a second" or a graceful miss | the conversation recovers on the next request |
| Mic permission denied | spoken note at launch, screen fallback | full base demo, operator drives by screen |
| Venue too loud | bad transcript, agent asks to repeat | push-to-talk limits the damage |

The rule across the table: the voice layer failing never takes down navigation or safety.

## Build milestones

These slot into [`07-timeline.md`](07-timeline.md) and have cut gates like every other tier.

| Milestone | What lands | Gate |
|---|---|---|
| **V0** | Mic captures, Deepgram returns a live transcript on device | a spoken sentence prints within 300 ms |
| **V1** | Voice Agent connected with Claude as LLM, one client-side function (`route_status`) round-trips | "where am I" speaks the real route state. Decide chosen vs fallback path here |
| **V2** | `set_destination` wired to `RouteEngine`, including the one clarifying question | spoken destination starts a real route |
| **V3** | `describe_surroundings` with the perception snapshot, draft plus verify | the spoken line never claims more than the snapshot supports |
| **V4** | text-to-speech confirmations, barge-in, `stop` | the wearer can interrupt, and stop always works |
| **V5 (stretch)** | `locate_entrance` and `read_text` over camera vision | one of them works on a walk-in test |

V2 is the line for a voice demo that means something. V4 is the line for a voice demo that feels finished. V5 only if the vision tier shipped.

## The demo moment

The wearer, blindfolded for the judges or genuinely low-vision, presses the button and says "take me to the coffee shop." The belt taps them into the first turn with no audio at all. Mid-walk they press and ask "what is around me," and hear one calm sentence: "Clear path, a person is stopped a few meters ahead on your right." They press once more, say "stop," and it stops. The point lands without a screen ever being touched.

## Blindspots and open questions

Ranked by how much they can hurt. Resolve the top ones before V1.

1. **Which button starts talking, when the wearer cannot see the screen.** The belt push-button is a stretch that needs a reverse channel the base protocol does not have (doc 04). Options: a hardware volume-button trigger on the phone, a full-screen invisible tap target, or the belt button if that stretch ships. Pick one early. This blocks the whole interaction model.
2. **Does the Voice Agent's Claude path plus client-side function calling actually behave on iOS.** Confirmed possible on paper, native Anthropic support is Haiku, BYO is OpenAI-compatible. Not yet proven from a Swift WebSocket client. V1 is the proof. The fallback path exists precisely because this might not hold.
3. **The perception snapshot does not exist yet.** `describe_surroundings` is blocked until the perception tier exposes the structured snapshot. This is a cross-tier dependency on doc 12. Flag it to whoever owns perception on day one.
4. **VoiceOver coexistence.** A real low-vision wearer may be running the iOS screen reader, which also owns audio and gestures. Our text-to-speech and our push-to-talk gesture can collide with VoiceOver. For the demo, decide whether VoiceOver is on or off, and test the gesture under both. This is the kind of thing that looks fine in rehearsal and breaks with a real user.
5. **Echo and barge-in.** Speaking while the mic is open invites the device to hear itself. The Voice Agent handles some of this server-side. Bench it before trusting it, and keep push-to-talk as the simple guard.
6. **Microphone permission is not declared.** Small fix, total blocker if missed. Already noted above. Add it in the first commit of this tier.
7. **Spoken guidance versus haptic cues during a turn.** If the wearer asks a question mid-turn, the answer and the haptic tap arrive together. Decide whether voice waits for the haptic, or talks over it. Lean toward letting the haptic lead, since it is the navigation channel.
8. **Cost and rate limits at demo time.** Trivial in dollars, but a rate limit or a cold API at the wrong moment ruins a live demo. Pre-warm the connection before going on stage, and have the replay route ready as the always-works fallback.
9. **Key safety in a client app.** Settled above: embed in the app for the demo (option A), or mint short-lived Deepgram tokens from a tiny endpoint if a hand is free (option B). Keys out of git, spend-capped, revoked after judging. A full proxy is the wrong trade for one phone we own.

## First three moves

1. Add `NSMicrophoneUsageDescription` and decide the push-to-talk trigger. Cheap, and it unblocks everything.
2. Build V0, mic to live transcript, to prove the audio path on the demo phone before any agent logic.
3. Build V1 with one function and make the chosen-versus-fallback call. Everything after V1 is the same whichever path wins.
