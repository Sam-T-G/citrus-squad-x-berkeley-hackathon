# 13 — Sponsor implementation ideas

How each Berkeley AI Hackathon 2026 sponsor could plug into WAND, scored from the perspective of the person who actually wears it: a blind or low-vision traveler. The goal is to find integrations that make the device more useful in real life, not integrations that only look good on a slide.

Pairs with:

- [`01-architecture.md`](01-architecture.md) — the three tiers and the data flows.
- [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md) — the phone module contract. Any new service named here has to obey it.
- [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md) — the safety reflex. The hard rule below comes from here.

## How to use this doc

This is a living menu, not a plan of record. Each sponsor gets a section with the same shape so they are easy to compare and easy to add to. When the team learns something new about a sponsor (a real API limit, a credit grant, a teammate who knows the stack), update that sponsor's section. The scoring rubric and the blank template at the bottom keep new entries consistent.

Nothing here is committed until it clears the [`07-timeline.md`](07-timeline.md) cut gates. Sponsor features are bonus layers on top of a demo that already wins without them.

## The one hard rule

**No sponsor touches the obstacle reflex.** The LiDAR-to-haptic loop in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md) has to stay local and instant. A person about to walk into a pole cannot wait on a cloud round-trip. Every integration in this doc lives on the *destination and information* path, which is allowed to be slower, allowed to use the network, and allowed to fail without anyone getting hurt. If a sponsor idea creeps toward the reflex, it is wrong.

The phone has cellular, so cloud calls are fine. The constraint that survived is latency and safety, not connectivity.

## What actually matters to a blind traveler

Every idea below is scored against these seven truths. They come from how blind pedestrians really move, and they are the difference between a useful aid and a gadget.

1. **The ears are the primary sensor.** Blind travelers localize traffic, footsteps, doorways, and echoes off buildings by sound. Flooding the ears with constant speech makes them *less* safe. This is the most important principle in the whole project. Continuous guidance belongs on the haptic channel. Voice should be sparing, on demand, and interruptible. The belt is valuable precisely because it keeps the ears free.

2. **The cane already solves the ground.** A white cane finds curbs, steps, and ground-level obstacles inside about 1.5 meters. It misses everything at torso and head height (tree branches, open doors, signs, side mirrors), anything beyond its reach, and it never tells you *what* a thing is. WAND should fill those gaps, not repeat what the cane already does well.

3. **The last fifty feet is the unsolved problem.** GPS lands you on a building's coordinate, not its door. Finding the actual entrance, the right door, the bus-stop pole, the crosswalk button: this is the hardest and most valuable thing an aid can help with, and the place where cameras plus reasoning can genuinely shine.

4. **Crossings are the high-stakes moment.** Where is the crosswalk, is the walk signal on, am I drifting out of the lane. High value, high difficulty, high risk of false confidence. Treat anything here with caution and never let it become the only thing the user trusts.

5. **Reassurance has value even when nothing changes.** Blind travelers lose heading easily and that breeds anxiety. A gentle "still on track" signal, carried on haptics so it costs no words, is worth a lot.

6. **Answer on demand, do not nag.** "What does that sign say." "Which bus is this." "Is this the entrance." "What is in front of me." These are pull, not push. The device waits to be asked. It does not narrate the world unprompted.

7. **Never give false confidence.** A wrong "obstacle" is annoying. A wrong "clear" or "cross now" is dangerous. Bias toward caution, and when confidence is low, say so or stay quiet rather than guess.

## Scoring rubric

Each sponsor is scored 1 to 5 on five axes, then given a tier.

- **Blind value** — does it serve a real, ranked need from the list above, or is it a buzzword.
- **Demo impact** — does it make the two-minute demo land harder.
- **Build cost** — 24-hour realism. 5 means cheap, 1 means a cold-start research project.
- **Core risk** — does it endanger the bulletproof base demo. 5 means fully isolated and safe to cut, 1 means it could sink the ship.
- **Incentive** — prize money and sponsor relationship.

Tiers: **S** build it, **A** strong add if a hand is free, **B** real but costs a dedicated owner, **C** cheap bolt-on for a secondary prize, **D** narrative or pitch-asset only, no product integration.

## At a glance

| Sponsor | Blind value | Demo impact | Build cost | Core risk | Incentive | Tier |
|---|---|---|---|---|---|---|
| Deepgram | 5 | 5 | 4 | 5 | 4 | **S** |
| Anthropic | 5 | 5 | 4 | 5 | 4 | **S / A** |
| Web AI | 4 | 4 | 3 | 5 | 3 | **B** |
| Fetch.ai | 3 | 4 | 2 | 4 | 5 | **B** |
| Sentry | 2 | 2 | 5 | 5 | 3 | **C** |
| Redis | 2 | 2 | 4 | 5 | 3 | **C** |
| Zoox | 1 | 3 | n/a | 5 | 3 | **D** |
| QNX | 1 | 1 | 1 | 5 | 2 | **D** |
| Midjourney / Pika / Adobe / Jukebox | 1 | 3 | 4 | 5 | 2 | **D** |
| Annapurna / Runpod / Arize | 1 | 1 | 2 | 5 | 2 | **D** |

---

## Tier S — build it

### Deepgram — the voice channel

**Blind value (5).** This is the input and the on-demand output for someone who cannot read the screen. Hands-free destination entry ("take me to Moffitt Library"), spoken confirmations, and on-demand questions ("what is around me," "where is the entrance"). It serves truths 1, 3, and 6 directly. The design discipline matters: voice carries setup and answers-when-asked, while the belt carries continuous guidance, so the ears stay free for the street.

**What it does in WAND.** A push-to-talk interaction. The wearer presses a button (phone, or the belt button if the stretch in [`04-phone-side.md`](04-phone-side.md) ships), speaks, and Deepgram returns text. The app speaks short confirmations back with Deepgram text-to-speech. Barge-in lets the wearer cut the device off mid-sentence, which matters because a blind user should never have to wait through a sentence they do not need.

**Where it sits.** A new `VoiceService` next to `LocationService` and `MotionService`, obeying [`11-phone-app-design-spec.md`](11-phone-app-design-spec.md). It hands a destination string to `DirectionsClient` and speaks results. It is nowhere near the heartbeat or the reflex. If it fails, the operator falls back to the screen and the replay route, and the demo is unharmed.

**Implementation sketch.**
1. Mic capture with `AVAudioEngine`, stream to Deepgram over a WebSocket (the public iOS sample app and Swift SDK both show this).
2. Push-to-talk gate so the mic is not always open. This also fixes venue noise, the main risk.
3. On final transcript, pass the string to destination resolution (raw to `DirectionsClient`, or through Claude first, see the stacked pipeline below).
4. Text-to-speech for three short lines only at first: "Heading to X," "Recalibrated," "Arrived." Keep speech rare on purpose.

**Effort / owner / risk.** Roughly 3 to 5 hours for push-to-talk entry plus three spoken confirmations. One owner. Main risk is venue noise, handled by push-to-talk and a noise-robust model. Full duplex Voice Agent API is a later upgrade, not the first cut.

**Prize.** Deepgram sponsors a challenge. Voice as the access modality for a blind user is the strongest possible story for them.

**Verdict.** Build first. It is the product, not a bolt-on, and it is the cleanest sponsor win on the board.

---

## Tier S / A — build it if a hand is free

### Anthropic — the reasoning and language brain

**Blind value (5).** Raw detections are useless to a blind walker. A list of forty seven boxes helps nobody. The value is the *translation* into one short, prioritized, human sentence, and into answers to real questions. Claude does three high-value jobs.

1. **Destination understanding.** "The coffee place near the north entrance" becomes a real place, and when it is ambiguous the device asks one clarifying question instead of guessing. This fits how blind users actually name places, which is rarely by street address. Serves truth 6.
2. **Prioritized scene narration on demand.** Feed Claude the YOLO classes plus LiDAR distances, optionally with a camera frame, and ask for one spoken sentence ranked by what matters to a walker: "Clear path. A person is stopped about three meters ahead on your right." Not a data dump. Serves truths 2 and 7.
3. **Read and reason about signs and entrances.** "What does that sign say." "Is this the library entrance." Claude vision reads the frame and answers. Serves truth 3, the last-fifty-feet problem.

**Where it sits.** A `NarrationService` and a `DestinationResolver`, both pull-only. They run when the wearer asks, or at a low cadence, never inside the 100 ms heartbeat and never in the reflex. Cloud latency of one to three seconds is fine for an on-demand answer and unacceptable for an obstacle, which is exactly why this lives on the information path.

**Implementation sketch.**
1. REST call to the Messages API. Likely covered by hackathon credits.
2. Start with text-only destination resolution: transcript in, structured place plus one optional clarifying question out.
3. Add scene narration: detections and distances in, one ranked sentence out, spoken through Deepgram.
4. Add the vision read for signs and entrances only if time allows after the base lands.

**Effort / owner / risk.** About 2 to 4 hours per feature. Easiest integration on the list. Risk is latency and cost, both fine at on-demand demo scale. Keep every call off the safety path and it cannot hurt the core.

**Prize.** Anthropic sponsors a challenge, and turning a perception stream into safe, plain-language guidance for a blind user is a clean fit.

**Verdict.** Build the destination-understanding piece right after Deepgram. It pairs perfectly: Deepgram hears and speaks, Claude thinks. Add narration if the base demo is solid.

---

## Tier B — real value, costs a dedicated owner

### Web AI — on-device narration

**Blind value (4).** Same scene-narration and sign-reading value as Claude, run on the phone instead of the cloud. For a blind user the wins are lower latency on repeated "what is in front of me" queries, no per-query cost, and it keeps working in dead zones. It also strengthens the "everything important runs on the phone" story, sitting next to the on-device YOLO that already exists in [`05-vision-tier.md`](05-vision-tier.md).

**Where it sits.** An on-device `NarrationService`, an alternative to the Claude narration path rather than an addition. Pick one brain for narration so the team does not maintain two.

**Implementation sketch.**
1. Bring up the Web AI Swift SDK and download an on-device vision-language model.
2. Run it over a single camera frame on demand, return a short description, speak it through Deepgram.
3. Bench the latency and the model size on the demo phone before committing.

**Effort / owner / risk.** Roughly 5 to 8 hours. Less battle-tested than a REST call, and on-device model bring-up always has surprises. Needs one owner who babysits it. Fully isolated, so safe to cut.

**Verdict.** A good "fully on-device, private" angle and a likely less-contested prize. It competes with Claude for the narration slot. Choose Claude if you want it working fast, choose Web AI if the on-device story is worth the extra hours.

### Fetch.ai — accessible trip planning agent

**Blind value (3, but real if executed).** The honest framing: a generic agent marketplace means little to this product. The one genuinely useful job is **accessible, multi-modal trip planning**. "Get me to my doctor's appointment" becomes walk, then transit, then walk, with the route chosen for step-free paths, fewer street crossings, and elevator over stairs. Plain Google Directions does not optimize for any of that. A journey agent that coordinates a maps agent, a transit agent, and an accessibility-preferences agent could produce a route a blind traveler would actually prefer. That is the only framing where Fetch earns its place instead of being buzzword theater. Serves truths 3 and 4 at the planning stage.

**Where it sits.** A cloud `JourneyPlanner` agent hosted on Agentverse, called once at trip start over a REST endpoint (`on_rest_post`) by the phone. It returns an accessible waypoint list that feeds `RouteEngine`. It never touches the heartbeat or the reflex, and the replay route is the fallback if it is slow or down.

**Implementation sketch.**
1. Build a uAgents agent in Python that takes a natural-language destination plus accessibility preferences.
2. Have it call a maps or transit source and rank routes for step-free, low-crossing paths.
3. Expose a REST endpoint, host on Agentverse, and call it from the phone at trip start.
4. Optionally use ASI:One as the front door that routes the request to the agent.

**Effort / owner / risk.** High, 8 to 14 hours, and the team has no current uAgents fluency. This needs its own owner for the whole hack and should not pull anyone off the base. Another network dependency at trip start, mitigated by replay.

**Prize.** The largest confirmed sponsor prize: 1500 / 1000 / 500 dollars plus internship interviews.

**Verdict.** Viable only as a stretch with a dedicated owner, and only with the accessible-routing framing. If nobody can own a Python side-quest end to end, skip it and let Deepgram plus Claude carry the AI story.

---

## Tier C — cheap bolt-on for a secondary prize

### Sentry — reliability instrumentation

**Blind value (2, indirect).** A mobility aid that crashes mid-walk is a safety problem, so crash and error monitoring is a responsible thing to add, and it gives the pitch an honest "we treat this as safety-critical" line. The wearer never sees it, which is why the value is indirect.

**Implementation sketch.** Drop the Sentry iOS SDK into the app, capture crashes and unhandled errors. Roughly 30 to 60 minutes. Fully isolated.

**Verdict.** Worth it if a teammate has a spare hour late in the build. Real secondary prize, near-zero risk.

### Redis — remembered routes and preferences

**Blind value (2).** If a backend exists, cache resolved routes, place lookups, and saved preferences so "take me home" or a frequent trip resolves instantly. Faster repeat trips and remembered accessibility preferences are a modest but real convenience.

**Implementation sketch.** Only viable if a server is in the loop (for example behind the Fetch journey agent). Store keyed routes and preferences. Skip entirely if the app stays phone-only.

**Verdict.** Only if a backend already exists for another reason. Do not stand up a server just for this.

---

## Tier D — narrative or pitch asset only

These have no clean product integration in 24 hours. Some still help the pitch.

- **Zoox.** No public SDK to integrate. Strong narrative though: the perception-and-path-planning idea that guides a robotaxi, pointed at guiding a person instead. Use it as a framing line in the pitch, not as code.
- **QNX.** A safety-certified real-time OS for embedded systems. The ESP32 cannot run it, and there is no bring-up path in the hack window. Note and move on.
- **Midjourney, Pika, Adobe, Jukebox.** Generative media. Ironic that they offer nothing to a blind user inside the product. They are useful for the demo video and pitch deck that sighted judges watch. Use them for the reel, not the device.
- **Annapurna Labs, Runpod, Arize.** Cloud training, GPU hosting, and ML observability. Only relevant if you train or fine-tune a custom model, which is out of scope when on-device YOLO is already chosen.
- **Everyone else on the roster** (the funds, the unrelated B2B tools, the beverage sponsor). No integration path for this product. List them here only if a real angle appears.

---

## What the sponsor resources confirmed

Three sponsor resources, ingested. They change how each integration should be built, because each one rewards using the core of the product rather than a thin call.

**Fetch.ai (resource doc).** The product is Agentverse plus ASI:One. ASI:One is the agentic LLM and discovery layer that finds the right agent and routes a request to it. Agents talk to each other over the Agent Chat Protocol, and they can transact through a Stripe payment protocol. The graded deliverables are an ASI:One chat session link, an Agent Profile for every agent you build, and a DevPost or GitHub writeup. Promo codes: `BERKELEYAIAV` for Agentverse, `BERKELEYAI` for ASI:One. The signal is loud. They want a discoverable multi-agent system you can talk to, not a single REST call.

**Anthropic (workshop slides).** The whole workshop is agentic patterns, not chat completion. Headline content: tool use (function calling), the five workflow patterns (routing, parallelization, orchestrator-workers, prompt chaining, evaluator-optimizer), the Model Context Protocol, retrieval, and a strict prompt-engineering method. They give an agent checklist that weighs task value against error cost. They name accessibility as a target use case. Reach for Haiku on the fast, frequent path and Sonnet on the hard reasoning.

**Deepgram (hackathon rule).** To qualify for Deepgram you must demonstrably use at least one Deepgram product: speech-to-text, text-to-speech, or the Voice Agent API. The flagship is the Voice Agent API, a single real-time stream that does speech-to-text, LLM orchestration, text-to-speech, function calling, barge-in, and turn-taking together. This requirement matters: if you want any Deepgram prize, voice is not optional, it is the entry ticket.

The common thread is that a thin call gets a thin score. The three designs below are built around each product's headline strength, and they happen to land on three different tiers of what independent travel actually requires.

## Deep dive: build to each product's headline strength

### Deepgram — the Voice Agent API is the whole interface

Headline strength: one real-time stream that hears, thinks, speaks, calls functions, and handles barge-in and turn-taking.

Purposeful design: do not bolt on bare speech-to-text. Make the Deepgram Voice Agent the entire conversational interface to WAND, and wire its function calling to real device actions. The agent's functions are WAND's capabilities.

- `set_destination(place)` starts routing in `RouteEngine`.
- `describe_surroundings()` returns the perception snapshot to speak.
- `locate_entrance()` runs a vision query for the last fifty feet.
- `read_text()` reads a sign, menu, or bus number off a frame.
- `route_status()` and `where_am_i()` give orientation and reassurance.
- `recalibrate()` re-runs the heading offset from [`04-phone-side.md`](04-phone-side.md).

Why this is native, not tacked on: barge-in and turn-taking are not extras for a blind user, they are the point. Someone who cannot see a screen needs to cut the device off the instant they have heard enough, and needs natural back-and-forth with no visual turn cues. That is exactly what the Voice Agent API gives, and the function calling turns a spoken sentence into a device action with nothing in between.

Blind-user payoff: hands-free, eyes-free control of every WAND capability, with the ears occupied only when the user chose to ask. Continuous guidance still lives on the belt, so the street stays audible. Serves truths 1 and 6.

How it composes: the Voice Agent API can run its think stage on your own LLM. Point it at Claude. Now Deepgram is the ears and mouth, Claude is the brain, and both sponsors are used for their actual strength in one path.

### Anthropic — Claude as the tool-using orchestrator with a safety verifier

Headline strength: agentic tool use plus the workflow patterns, with a real method for controlling hallucination.

Purposeful design: Claude is not a describe-the-scene call. It is the reasoning agent that orchestrates WAND's perception tools and decides what is worth saying. Build it from the workshop's own patterns.

- **Tool use.** Give Claude tools that read real state: `get_perception_snapshot()` (YOLO classes plus LiDAR distances), `read_frame()` (camera vision), `get_route_state()`, `set_destination()`, and `speak()` through Deepgram. This is the workshop's central lesson applied directly.
- **Routing.** Send each spoken request to the right capability: navigate, describe, read a sign, find an entrance.
- **Evaluator-optimizer for safety.** This is the standout. Any line that could create false confidence runs two passes. A drafter writes the spoken guidance. An evaluator checks it strictly against the raw perception data and withholds or downgrades anything the data does not support. The device never says "clear to cross" unless the perception actually backs it, and when confidence is low it says so instead of guessing. That is truth 7 turned into a mechanism, built from a headline pattern rather than decoration. It is also the workshop's own advice: high error cost earns a verification step.
- **Prompt-engineering discipline.** Feed perception in as XML-structured input, prefill the short spoken format, give three to five examples of good prioritized narration, and repeat the critical safety instruction. The slides prescribe exactly this.

Model split, by their checklist: Haiku on the frequent fast path (routing a request, a one-line narration) for latency and cost, Sonnet on the hard problems (an ambiguous destination, finding the right entrance from a frame).

Optional flex: expose WAND perception as an MCP server named `wand-perception` with tools and resources, so Claude reaches the sensors through the standard protocol. On brand and a clean story, but only if the base is solid.

Blind-user payoff: raw detections become one short, prioritized, verified sentence, on demand, and the system errs toward caution instead of confident nonsense. Anthropic names accessibility as a target use case, so this sits squarely in their lane. Serves truths 2, 3, and 7.

How it composes: Claude is the LLM behind the Deepgram Voice Agent and the orchestrator behind the perception tools. One brain, two jobs.

### Fetch.ai — the transactional tier, where blind independence actually breaks

Headline strength: ASI:One discovery and routing, a multi-agent chat protocol, and agent-to-agent payment over Stripe.

The reframe that makes it purposeful: the phone and the belt solve the physical last mile. Fetch solves the transactional last mile. For a blind traveler the hard part is often not the walking, it is the ordering, the paying, and the booking of accessible transport, the steps that need sight and a screen. An agent mesh that can discover peers and transact is built for exactly that.

Purposeful design: a small set of agents registered on Agentverse, discoverable through ASI:One.

- **Concierge agent, the ASI:One front door.** The wearer speaks a goal: "get me to the coffee shop, have my usual ready, and book an accessible ride home at four." ASI:One discovers and routes to the workers. This is the ASI:One chat session deliverable, satisfied honestly.
- **Accessible-routing agent.** Plans a step-free, low-crossing walking route and returns waypoints to the phone for `RouteEngine` to drive.
- **Order-ahead agent.** Places the order and pays through the Stripe payment protocol so it is ready on arrival.
- **Mobility-booking agent.** Books and pays for paratransit or a rideshare, again through the payment protocol.

Each agent has an Agent Profile, the second deliverable. The agents coordinate over the Agent Chat Protocol, the headline multi-agent feature, and the payment protocol does real work instead of sitting in a slide.

Why this is native, not tacked on: discovery, delegation, and payment are the product, and they map onto genuine blind-traveler pain. Ordering and paying without sight, and arranging accessible transport, are real barriers to independence. An agent that does them on request is worth something. Serves truths 3 and 4 at the planning and errand stage.

Blind-user payoff: the errands and the transport that usually require a screen and a card happen by voice, while the belt handles the walking.

Cost and risk, unchanged and honest: high, Python, and the team has no current uAgents fluency. This needs its own owner for the whole hack and must not pull anyone off the base. It is the largest prize on the board, so it is worth one dedicated person if a hand is free.

How it composes: the concierge is spoken to through the Deepgram Voice Agent, and ASI:One or Claude is the language layer. The walking output drops into the same `RouteEngine` the base already drives.

---

## The four tiers, one device

Read in order, the three sponsors are not competing features. Each owns a distinct tier of independent travel, and each uses its headline product for what it is actually best at. The WAND core sits in the middle, and the obstacle reflex sits underneath, untouched.

```
TALK     Deepgram Voice Agent     hears, speaks, barge-in, turn-taking, function calls
ERRANDS  Fetch ASI:One + agents   discover, plan accessible route, order ahead, pay, book ride
THINK    Claude tool use          orchestrate perception, narrate, verify before speaking
MOVE     WAND core (RouteEngine)  bearing math, quadrant, LC2 packets, belt haptics
                                   continuous guidance, no words, ears stay free

REFLEX   LiDAR -> belt            always local, instant, never in the chain above
                                   the one hard rule
```

One spoken request can flow TALK to ERRANDS to THINK to MOVE and back, targeting Deepgram, Fetch.ai, Anthropic, and your Ddoski's Lab track in a single coherent demo, while the REFLEX that makes the base bulletproof never depends on any of it.

## Recommended combination for the hack

1. **Deepgram Voice Agent first, once the base lands.** It is the entry ticket for any Deepgram prize and it is the right interface for a blind user anyway. Build it as the conversational front end with function calling wired to WAND actions, not as bare speech-to-text.
2. **Claude as the brain behind it.** Point the Voice Agent's think stage at Claude, give it the perception tools, and add the evaluator pass before anything safety-relevant is spoken. Haiku on the fast path, Sonnet on the hard reasoning. Cheap, on theme, and it turns the voice layer from a microphone into an agent.
3. **Fetch.ai only with a dedicated owner** who can carry a uAgents mesh end to end, using the transactional-tier framing and hitting both deliverables (ASI:One chat session plus an Agent Profile per agent). Largest prize, highest cost. One person owns it for the whole hack or it does not get built.
4. **Sentry late, if a spare hour appears.** Free secondary prize.
5. **Generative media for the pitch reel,** not the product.

Two facts to plan around. Deepgram use is mandatory for its prize, so voice is the anchor, not a nice-to-have. Fetch wants a discoverable multi-agent system you can talk to, so a single REST call will not score, which is why it costs a dedicated owner.

Hard guardrail, repeated because it is the one that matters: every one of these lives on the talk, errands, and think tiers and fails gracefully to the replay route. None of them go near the LiDAR obstacle reflex.

---

## Template for adding a sponsor

Copy this block when adding a new sponsor so entries stay comparable.

```
### <Sponsor> — <one-line angle>

**Blind value (score).** Which of the seven truths it serves, and how. Be honest
if the answer is "mostly a pitch line."

**What it does in WAND.** The concrete feature the wearer would feel or use.

**Where it sits.** The module and tier. Confirm it is off the obstacle reflex.

**Implementation sketch.** Numbered steps, smallest useful cut first.

**Effort / owner / risk.** Hours, how many people, what could go wrong.

**Prize.** What the sponsor offers, if known.

**Verdict.** Build, stretch, cheap-add, or pitch-only, and why.
```

Scores go in the at-a-glance table using the rubric: blind value, demo impact, build cost, core risk, incentive, each 1 to 5, then a tier.
