# Pitch notes

Living notes for the demo pitch. First entry is the Claude and Deepgram impact story, the tool surface the voice agent chooses from, and the claims that are true to make on stage. Add new pitch notes under their own headers below.

## The problem to open with

GPS lands a blind traveler on a building's coordinate, not its door. A white cane finds the ground inside about 1.5 meters, but not a sign, an open door, a side mirror, or anything at head height. And the ears are a blind traveler's primary sensor, the way they localize traffic, footsteps, and doorways, so a device that talks constantly makes them less safe, not more.

Citrus Squad answers all three. Continuous guidance rides on the belt so the ears stay free for the street, and the wearer has a voice they can ask, only when they need it. Two sponsors carry that interface, each used for what it is actually best at.

## Deepgram: the whole interface, not transcription

The Deepgram Voice Agent is one real-time stream that hears the wearer, handles turn-taking and barge-in, and calls device functions directly. "Take me to Moffitt," "what is around me," "read that sign" become real device actions through function calling, with no screen ever touched. Barge-in is the point for this user, not an extra: a blind wearer has to be able to cut the device off the instant they have heard enough. We built on the flagship Voice Agent API and wired its function calling to real navigation, perception, and belt actions, rather than bolting on bare speech-to-text.

## Claude: the judgment and the eyes

A list of forty detections helps nobody who cannot see. Claude turns the sensor stream into one short, prioritized, spoken sentence, and it reads the world's text: store signs, bus numbers, door labels. On the describe path Haiku drafts the line and a stronger model (Sonnet) verifies it against the scene before it is spoken; Opus vision reads fine print from a single camera frame.

The part that earns trust: the device refuses to give false confidence. A local guard rejects any "the path is clear" line the LiDAR contradicts, and every high-stakes read, a medication name or a door number, gets hedged with a "double-check this." Claude never touches the obstacle reflex. That stays deterministic LiDAR-to-haptic and never waits on a network call.

## Why each sponsor should care

- **Deepgram.** We used the Voice Agent API, their headline product, with function calling driving real device actions. Turn-taking and barge-in are core to a blind user's experience, so this is a deep integration, not a thin call.
- **Anthropic.** Accessibility is a use case they name directly. We used the workshop's own patterns: tool use through function calling, routing through a tiered system that answers each request at the cheapest correct level, and the evaluator-optimizer pattern on the describe path, where a fast model drafts and a stronger model verifies the draft against the scene before a word is spoken, with an on-device guard as an instant backstop. Haiku on the fast path, Sonnet on the verify, Opus on vision. Raw perception becomes safe, plain-language guidance.

## The line that lands

Most teams oversell. This device says "I am not sure, check this" on a risky read, and it stays quiet rather than guess. For a tool a blind person leans on, that restraint is the product.

## The tool surface the voice agent chooses from

The wearer speaks; the Deepgram Voice Agent picks which function to call and speaks the result back. Claude does the judgment and vision work inside the Tier 2 and Tier 3 tools. Everything else answers instantly from on-device state or one small map call, so the device never waits on a model it does not need.

| Tool | What the wearer gets | Tier | Where the intelligence is |
|---|---|---|---|
| `read_sign` | Reads a sign, label, or number from one camera frame and says it back | 3 | Claude Opus vision, hedged when unsure or high-stakes |
| `locate_entrance` | Finds a door or entrance and says roughly which way, never a distance | 3 | Claude Opus vision |
| `describe_surroundings` | One prioritized sentence about what is ahead for a walker | 2 | Claude Haiku drafts, Claude Sonnet verifies the draft, an on-device guard backstops |
| `set_destination` | Speak a place name; it builds a real route and starts the live walk | 1 | Apple place search and route, no Claude |
| `where_am_i` | Current location as a nearby place or address | 1 | GPS reverse geocode, no Claude |
| `route_status` | Distance to the next turn and how many turns remain | 0 | On-device, instant |
| `next_turn` | Which way the next turn is and how far ahead in feet | 0 | On-device, instant |
| `trip_summary` | Distance and rough walking time to the destination | 0 | On-device, instant |
| `check_path` | Whether a person or object is in the path and which side is open | 0 | LiDAR geometry, kept instant and on-device on purpose |
| `recalibrate` | Recapture the forward-facing heading offset | 0 | On-device, instant |
| `connect_belt` | Connect to the haptic belt so it can start tapping | 0 | On-device, instant |
| `disconnect_belt` | Disconnect from the belt | 0 | On-device, instant |
| `stop` | Stop navigation and guidance now, the brake | 0 | On-device, instant |

Tiers, plain version: Tier 0 is instant on-device logic with no model and no network. Tier 1 is one Apple or Google call. Tier 2 is a Claude judgment call with a local safety guard. Tier 3 is a Claude vision read of one camera frame. A request is always answered at the lowest tier that can answer it correctly.

## Claims to make, and claims to avoid

True to say:
- The Deepgram Voice Agent is the full conversational interface, with function calling wired to real device actions.
- Claude describes scenes and reads the world's text, with Haiku on the fast path, Sonnet on the verify, and Opus on vision.
- On the describe path a fast model drafts, a stronger model verifies the draft against the scene, and an on-device guard backstops both. This is the evaluator-optimizer pattern from Anthropic's workshop.
- A guard blocks a false "all clear," and high-stakes reads are hedged.
- AI never touches the obstacle reflex; the belt is driven by on-device LiDAR geometry.

Do not say:
- "Claude is the LLM behind the Voice Agent" or "Claude is the think tier." The think stage runs on Deepgram-managed `gpt-4o-mini`, because the managed Claude model is not provisioned on our Deepgram account. Attribute the conversation and tool-selection to Deepgram, and the judgment and vision to Claude inside the functions.

## Open items before judging

Both of these are now implemented. Confirm them on the phone before judging.

- **Vision schema pre-warm (done).** `prewarm()` now compiles the read and verify schemas at launch, so the first `read_sign` does not pay a cold schema compile. Confirm the first read lands on device.
- **Evaluator-optimizer (done).** The describe path now runs Haiku draft, on-device guard, then Sonnet verify, all inside one voice budget (verify only uses the budget the draft left, so it should not stall the turn). Confirm `describe_surroundings` still answers within the turn on device.
