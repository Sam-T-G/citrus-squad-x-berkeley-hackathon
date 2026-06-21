# Blind Navigation North Star

The grounded answer to "what is truly valuable for blind travelers, and where can AI make a real
difference." This is the synthesis of a deep research pass (lived experience, orientation-and-mobility
fundamentals, the 50-year graveyard of failed travel aids, the 2023-2026 AI-product landscape, ranked
unmet needs, AI capability and risk, form-factor and adoption science, equity and economics) plus four
adversarial expert reviews (a blind cane user, an assistive-technology-abandonment researcher, a
disability-justice critic, and a product-economics critic). It weights blind community voices over
engineering intuition, and it carries the criticism of our own product all the way through.

It is the reference for what we build and why. The implemented tools that follow from it live in
[`VOICE-AI-PIPELINE.md`](VOICE-AI-PIPELINE.md) and [`AI-USAGE-AUDIT-AND-EXPANSION.md`](AI-USAGE-AUDIT-AND-EXPANSION.md).

---

# Where AI Can Create Real Meaning in Blind Navigation — and Where Citrus Squad Should Actually Aim

A synthesis weighted toward blind community voices, carrying the adversarial critiques forward rather than around them. This document is opinionated by design and partly rejects the product's current premises.

---

## 1. The uncomfortable truths about blind navigation technology

**The white cane is winning, and it has been winning for eighty years.** A $20–60 painted aluminum stick beats every electronic competitor on the metrics that decide adoption: cost, weight, all-day-and-then-some battery (it has none to drain), zero training friction relative to electronics, and direct tactile ground truth. In head-to-head trials, electronic canes produce *slower* walking speeds, not faster ([Universal Access in the Information Society, 2020](https://link.springer.com/article/10.1007/s10209-020-00712-z)). User-satisfaction data puts the white cane at ~4.0/5 and the guide dog at ~4.67/5, while high-tech audio/haptic devices sit at 3.5 ([UC Davis survey, arXiv 2504.06379](https://arxiv.org/pdf/2504.06379)). The "old" tools are not failing tools the community is desperate to escape. They are trusted, and the cane is identity, not just equipment ([SJDR](https://sjdr.se/articles/10.16993/sjdr.1222); [WGBH](https://www.wgbh.org/news/local/2025-10-24/mass-blind-community-celebrates-white-cane-as-a-symbol-of-freedom-and-independence)).

**Most "blind navigation" tech solves a problem the cane already solved, and ignores the one it didn't.** Obstacle detection — the canonical "help the blind avoid bumping into things" framing that consumes most engineering effort — ranks *below* indoor navigation and POI-finding as an unmet need in survey data ([Tandfonline 2025](https://www.tandfonline.com/doi/full/10.1080/17483107.2025.2544942)). The cane reliably previews ~1.2 m of ground, detects curbs, drop-offs, and stairs (the fall-prevention job that matters most), reads texture transitions, supports shorelining, and even functions as active sonar via the tap ([PMC6292384](https://pmc.ncbi.nlm.nih.gov/articles/PMC6292384/)). The genuine cane gap is narrow and specific: head- and chest-height overhangs (branches, signs, truck mirrors, scaffolding — over 10% of cane users take a head injury about *once a month*), and *approaching* hazards the cane only senses on contact. Re-solving ground obstacles is the most common engineering mistake in the category.

**The graveyard is enormous and the failure modes are structural.** Through 1985, no more than ~3,000–3,500 ultrasonic ETAs were ever sold in the US across the *entire category* ([PMC6696419](https://pmc.ncbi.nlm.nih.gov/articles/PMC6696419/)). Sensory-substitution devices (the vOICe, BrainPort tongue display, Bach-y-Rita tactile arrays) fail on *cognitive overload* — interpreting the substituted signal never becomes automatic, so the rich real world floods a low-bandwidth channel into noise. This is not a tuning problem; it is structural. Abandonment of electronic mobility aids specifically is estimated around **75%** ([NIBIB](https://www.nibib.nih.gov/sites/default/files/Sensory%20Substitution%20Glove.pdf)), versus a ~29% all-device baseline ([Phillips & Zhao 1993](https://pubmed.ncbi.nlm.nih.gov/10171664/)).

**Three of the four statistical predictors of abandonment are about process, not capability**: the user's opinion wasn't considered in selection, the device was procured too casually, and the user's needs changed (only the fourth, poor performance, is about the device itself) ([Phillips & Zhao](https://pubmed.ncbi.nlm.nih.gov/10171664/)). You can build a technically flawless device and still earn a drawer if you skip co-design and training.

**Hearing is navigation infrastructure, not background noise.** Blind travelers time street crossings by the engine sound of traffic; they localize quiet EVs, cyclists, and echoes off buildings. This is exactly why silent EVs are a safety crisis ([European Blind Union](https://www.euroblind.org/campaigns-and-activities/finished-campaigns/silent-cars)) and why headphone-based audio guidance can be actively *dangerous*. The well-meaning engineer's instinct — "it's audio, blind people listen, perfect" — is close to backwards.

**Corporate abandonment now outranks technical failure.** Toyota walked away from BLAID after ~$300M before release; Microsoft killed the beloved Soundscape in 2023 despite a petition; OrCam shut its entire vision division in 2024; the Sunu Band and BuzzClip were discontinued, stranding their users ([Frontiers 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12832816/)). Blind users have learned, rationally, to be skeptical of any new entrant — they invest months of O&M training into a tool and watch it die. **Durability and continuity are now features, not afterthoughts.**

---

## 2. What the blind community actually values, ranked — real needs vs. sighted-technologist projections

This ranking weights community voice and survey data over engineering intuition. Where the two diverge, I say so.

**Tier 1 — The genuinely unmet, decisive needs**

1. **Last-mile / last-50-feet micro-navigation.** Getting from "GPS put you within 5–10 m" to "your hand is on the door handle / you are at the bus pole / you are at the correct bus door." This is the single most consistently named gap where mainstream tools fail and the consequence is *task failure* — "a miss is as good as a mile" ([AppleVis](https://www.applevis.com/forum/ios-ios-app-discussion/which-navigation-apps-would-people-recommend-blind-iphone-user)). GPS is *least* accurate exactly where the user needs it *most* (5 m+ urban error, premature "you have arrived" while still in the street). The All_Aboard transit study found mainstream maps got "close enough" to a bus stop only 52% of the time (avg 6.62 m off) vs. 93% with micro-nav (1.54 m) ([Mass Eye and Ear](https://masseyeandear.org/news/press-releases/2024/01/all-aboard-app-effectively-aids-blind-and-visually-impaired-commuters)).

2. **Reading text/signage in the wild** — room numbers, door names, bus-stop signs, menus, mail, labels, inaccessible touchscreen kiosks. Arguably the most frequent *daily* frustration, and the first thing the new multimodal AI is described as a genuine "game changer" rather than a toy. The bottleneck is **aiming the camera, not recognition** — better OCR doesn't help if a blind user can't frame the sign ([PMC6824725](https://pmc.ncbi.nlm.nih.gov/articles/PMC6824725/)).

3. **Indoor orientation and wayfinding** — malls, airports, clinics, transit hubs, campuses. The #2 surveyed unmet need and the area GPS *structurally* cannot serve. This is precisely why Aira's *human* agents dominate airports ([Tandfonline 2025](https://www.tandfonline.com/doi/full/10.1080/17483107.2025.2544942)).

4. **End-to-end transit micro-navigation** — confirming the right vehicle arrived, finding the correct door (multi-car trains are named explicitly), knowing when to alight. Errors cascade and carry time/safety stakes ([NSF](https://par.nsf.gov/servlets/purl/10063454)).

**Tier 2 — Real, but bounded or partly an infrastructure problem**

5. **Street-crossing support** — high-stakes, but the hard sub-tasks (locating/aligning to the pushbutton, heading alignment) are partly an Accessible Pedestrian Signals *infrastructure* problem an app can only partially substitute ([APS guide](http://www.apsguide.org/chapter2_travel.cfm)).

6. **Silent-EV / moving-vehicle awareness** — a validated safety concern, but the recognized fix is regulation (AVAS minimum-sound mandates), and the traveler's own trained hearing is the primary tool. A weak place for an app to claim to win.

**Tier 3 — Valued bonuses, not headlines**

7. Finding specific objects (keys, an empty seat, a product). 8. Social/contextual cues (facial expressions, is the shop open) — desired, anxiety-reducing, but lowest in stated priority and shakiest in accuracy.

**What sighted technologists systematically over-rate**

- **Generic obstacle detection / "smart cane" replacement.** "Many startups try to replace the white cane, but research has uncovered that nobody who uses a white cane actually wants that" ([Thomasnet](https://www.thomasnet.com/insights/smart-cane-helps-blind-people-navigate-the-world/)). Bhavya Shah (fully blind, Stanford): the smart cane "may be based on a misconception about cane travel... When I hit an object, my cane makes a certain sound, and that's precisely what its job is." Cricket Bidleman names the real harm as ableism, and her honest reaction to being asked to be excited was "frustration and lack of enthusiasm" ([Stanford Daily](https://stanforddaily.com/2021/11/14/concerns-arise-for-the-development-of-smart-cane-to-assist-the-blind/)).

**The cross-cutting truth that outweighs all of it:** the make-or-break variable is **abandonment, not capability**. 87% of blind/low-vision users say they're interested in AI assistants — demand is not the bottleneck, *retention* is, and retention is killed by stigma, lack of training, app-juggling, and "feasible-not-useful" design ([Frontiers 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12832816/)).

**And the demographic correction that should reframe everything:** the modal user is **not** the young, totally-blind, AppleVis power user the community's loudest voices conjure. ~85% of legally blind people retain usable vision; ~60% are 65+; two-thirds of the legally blind are seniors who lost sight to age-related disease ([Vision Center](https://www.visioncenter.org/resources/elder-vision-statistics/); [NCOA](https://www.ncoa.org/article/understanding-older-adults-with-vision-loss-and-how-to-help/)). They navigate by *residual sight* and want visual enhancement, not audio-first turn-by-turn. ~1 in 3 also has hearing loss; ~36% have diabetes (and diabetic neuropathy dulls the very foot/haptic feedback the cane and any belt depend on). They are phone-averse, jargon-allergic ("What the hell is the rotor?!"), and often refuse aids because accepting one feels like "giving up that goal of mine, which is to get my vision back" ([arXiv 2409.03086](https://arxiv.org/html/2409.03086v1)). And 89–90% of the world's blind population lives in low/middle-income countries, where a phone-tethered powered belt is a non-starter ([WHO](https://www.who.int/news-room/fact-sheets/detail/assistive-technology)).

---

## 3. Where AI genuinely changes the equation in 2026 — and where it must NEVER be the sole authority

**The real, defensible leverage of AI is semantic compression.** Every dead ETA failed by faithfully transmitting the rich environment — sonifying pixels, buzzing for every echo — and overloading the channel into noise. AI's structural edge over fifty years of failure is that it can output *minimal, decided, human-language* guidance: "door ahead on your right, three meters," instead of a raw sensory dump the user must consciously decode ([PMC6696419](https://pmc.ncbi.nlm.nih.gov/articles/PMC6696419/)). **Conveyed-information minimization is the single most important lesson the category offers, and it is the one thing language models are actually built to do well.**

**Where AI genuinely delivers in 2026** is *static, non-time-critical* description: reading a held-still menu, mail, label; identifying an object; checking color/clothing; conversational follow-up. AccessWorld's Ray-Ban Meta reviewer called menu-reading "magical" ([AFB](https://afb.org/aw/fall2025/meta-glasses-review)). Be My AI resolves customer-service queries in ~4 minutes with only 10% human escalation. This is the validated sweet spot, and it maps onto the #2 community need (reading in the wild). The OrCam collapse proves it: a $4,500 dedicated device died in 2024 because the company itself admitted smartphone LLMs now do its job ([Calcalist](https://www.calcalistech.com/ctechnews/article/hy0rv6qya)).

**Where AI fails dangerously is exactly what navigation needs: spatial reasoning and distance.** Zero-shot VLMs cluster at **38–52% median error** on scale/distance; distance estimation is "a blind spot of current state-of-the-art VLMs like GPT-4V"; models misstate left/right and have no robust internal coordinate system ([HuggingFace](https://huggingface.co/blog/KBayoud/spatial-reasoning-in-vlms); [arXiv 2503.01773](https://arxiv.org/html/2503.01773v3)). Out-of-the-box VideoLLMs recognize environmental *hazards* — the safety-critical job — at **25% accuracy**, rising to only ~76% after dedicated fine-tuning; 76% is nowhere near safe ([arXiv 2505.04488](https://arxiv.org/pdf/2505.04488)). And the worst failure isn't being wrong — **it's being wrong with no hedge.** On spatially unanswerable questions, models answer confidently anyway, scoring below 10% (one at 1.1%, below the random baseline); they almost never say "I can't tell" ([arXiv 2605.30557](https://arxiv.org/html/2605.30557)).

**Two facts make this uniquely dangerous for blind users.** First, the *verification gap*: a blind user lacks the ground truth to catch a hallucination a sighted user would laugh off ("it called my white cane a hiking pole," "described a raincoat's clouds-and-raindrops as hearts-and-stars," "called a cat a rattlesnake") ([arXiv 2604.00187](https://arxiv.org/html/2604.00187); [arXiv 2408.06546](https://arxiv.org/html/2408.06546v1)). Second, the *fluent voice actively engineers overtrust*: "If it suddenly sounds human and if it's giving you all of this reputable-sounding information... Are you going to take it more realistically?" (P23). The polish engineers are proud of is a risk multiplier.

**Latency and connectivity finish the case.** Cloud VLM round-trips run 1.5–3.0s *each* — "avoid now" becomes "avoid too late" — and die offline, exactly where outdoor mobility most needs them ([Milvus](https://milvus.io/ai-quick-reference/what-are-the-challenges-in-using-visionlanguage-models-for-realtime-applications)).

**The hard line, therefore:** AI may **describe** but must **never be the sole authority** for any decision where a wrong answer causes physical harm — street crossings, stairs/drop-offs, moving-obstacle avoidance, "is it safe to proceed." Those belong to the cane, the guide dog, O&M skill, and — when augmentation is wanted — a *trained, accountable human* (Aira-style), not a confident model. Note the liability asymmetry: Aira's agents are contractually obligated to go *silent* during crossings; Be My Eyes' terms say the service is "as is," "do not rely on," "do not use to cross the street." **The safest design choice was to remove the AI from the decision, not to improve it.** Crucially, blind users *already* triage by stakes — "If it's medicine, I double-check; if it's a can of soda, I don't care if it's Coke or Pepsi" (P1). A good product encodes that workflow; it does not override it.

---

## 4. An honest assessment of Citrus Squad

I'll be direct, because all four adversarial reviewers — a lifelong cane user, an abandonment-literature lens, a disability-justice lens, and a hard-nosed economics lens — converged on the same verdict from different directions. That convergence is itself a signal.

### What is genuinely differentiated and worth keeping

The **architectural discipline of keeping AI off the haptic decision path is correct and rare.** The belt cue derives from deterministic on-device LiDAR geometry; every Claude failure returns `nil` and falls back to a sensor-grounded string; the heartbeat never blocks on a network call. The `SpokenLineGuard` (refusing a Claude line that claims a clear path the LiDAR contradicts) is the right *shape* of defense — local, instant, no second API call. Preferring GPS course-over-ground over a belt-magnet-poisoned magnetometer is a correctly diagnosed mitigation. And the team's own **AI-USAGE-AUDIT is unusually honest** — it openly states the live "think" model is gpt-4o-mini (not Claude), the Claude tier is unrun on device, and the hardware is unproven. That candor is a survival asset; most hackathon teams oversell.

### What is abandonment-bait

**The belt is the most expensive, fragile, stigmatizing, and least-proven part of the system, and it is sold as the wedge.** By the team's own STATUS.md, the servo PWM, the LC2 round-trip to real hardware, LiDAR behavior at the chest angle, thermals, and the on-device voice layer are *all unproven on a body*. The thing the user is asked to "wear and trust daily" has never been worn for a single real walk. The abandonment literature is unforgiving: this is the prototypical demo-that-works, drawer-in-a-month case — and it hasn't even reached demo-on-a-body. A visible four-servo belt wired to an ESP32 is conspicuous, disability-coded hardware (a decisive abandonment driver), it's a second device to don/pair-over-WiFi/charge/maintain, and it competes against a $34 cane-clip that runs 30+ days offline.

### The belt-versus-cane reality

The belt **re-solves the half of the problem the cane already owns** (ground-level obstacles ahead) while **leaving the face unprotected** from the overhangs the cane actually misses — and a chest-mounted, floor-dodging, torso-height LiDAR scan is *worst* positioned to catch head-height branches and signs. That is precisely inverted from where the value is. Worse, the obstacle/stop alert rides **best-effort UDP-over-WiFi** to the ESP32, with the belt falling silent after 500ms of packet loss — a *silent failure indistinguishable from "clear path,"* the single worst failure mode in this domain, and a direct echo of the one documented field-reliability failure in the literature (a physical link disconnection, not an algorithm). And the four servos are asked to carry turn-by-turn *and* avoidance-steer *and* stop on the same motors: when the belt taps left, is that "route turns left" or "obstacle, steer left"? That ambiguity is the cognitive-overload trap that killed sensory substitution.

There is also a **directional safety inversion left unresolved**: `DepthService.bandedNearest` carries a literal comment that left/right may be mirrored and a human must swap two lines after a live test. For a safety cue, a 50/50 unverified chance that "obstacle on your left" means your right is not a footnote — it's a bug that would steer the wearer *into* the hazard.

### Whether the belt or the voice/vision tier is the real value

**The voice/vision tier is the real value; the belt is not.** Voice-set destination plus on-demand sign/scene reading targets the genuinely top-ranked needs (in-the-wild reading, orientation). But two things must be said plainly. First, the marquee Claude scene-understanding tier is, by the team's own audit, **never run on device** — selling it as a shipped differentiator is wishful thinking, and the VLM it would use hallucinates 22–34% on exactly the high-stakes sign/dose reads it would perform, with no uncertainty signal. Second, `locateEntrance()` is a single-frame "roughly where is the door, how far" call — *precisely* the distance-and-direction estimate VLMs are documented to be worst at — fed to a user who cannot catch the fabrication. The `SpokenLineGuard` blocks a false "all clear" but does nothing about a confident "entrance is ahead about five meters" that walks the wearer into a planter.

### The line the product crosses

The `check_path` voice function instructs the agent to "tell the wearer to step left, step right, or stop" — **directive, safety-critical output from a noisy single-band LiDAR read.** This is the move that (a) makes a machine decide *for* a blind traveler, the inverted-cane harm Shah and Bidleman name; (b) blows the FDA Non-Device CDS criterion and the EU MDR Rule 11 "decision-making" trigger; and (c) matches the exact intended-use phrasing — "orientation and mobility aid for blind patients" — that pulled BrainPort into FDA Class II prescription-device territory ([Federal Register](https://www.federalregister.gov/documents/2015/09/22/2015-24026/medical-devices-ophthalmic-devices-classification-of-the-oral-electronic-vision-aid)). A disclaimer will not save it; for personal injury, exculpatory clauses are routinely void as against public policy, and an injured blind user is the paradigm public-interest/unequal-bargaining case ([50-state survey](https://www.mwl-law.com/wp-content/uploads/2018/05/EXCULPATORY-AGREEMENTS-AND-LIABILTY-WAIVERS-CHART.pdf)).

### The provenance problem that precedes all the code

There is **no evidence of a single blind person in the room** — no co-design, no blind tester, no O&M consult. The "supplement to the cane" framing lives in exactly one pitch document (`docs/09`) and nowhere in the product; the README pitches the belt as a standalone "which way to turn or move... No screen. No audio required" device. By the team's own admission, "the team-member wearer is the demo" and the team will "describe what a real cane user gains." That is sighted people narrating the blind experience on a blind person's behalf — the textbook disability-dongle pattern, and the single strongest predictor of abandonment.

**Verdict, in one sentence:** Citrus Squad gets the hardest *architectural* call right (AI strictly off a deterministic, on-device, ears-and-hands-free haptic channel) and then aims that good engineering at the two problems the community least needs solved (macro turn-by-turn that free apps already do, and near-field obstacle detection the cane already owns), while pushing its one safety-critical alert across a wireless hop that can fail silently, crossing the describe-don't-decide line with directive steer/stop output, and shipping it without one blind person on record.

---

## 5. The wedge: the specific, winnable, high-value problem to own

A wedge is not a feature stack — and "fuses everything on the phone you own" is not a wedge, it is **the exact value proposition that just killed OrCam**, because every fused layer is matched or beaten by a free app on the same phone. The bar is not "it works." The bar is **better-than-free, *and* worth the marginal cost of carrying anything beyond the phone.**

The honest, defensible wedge is the intersection of *high community demand*, *structural gap incumbents can't close*, and *something a small team can actually ship*:

> **Aiming-tolerant, last-50-feet final approach plus in-the-wild reading — the "you are at the right block, now get me to the actual door and confirm I'm there" problem.**

This is winnable for specific reasons grounded in the localization research:

- **It is the #1 and #2 ranked unmet need**, and the place GPS is structurally weakest (5–25 m error, arrival announced mid-street, dead indoors).
- **It is the one place AI's static-description strength and a small team's deployment reach actually align.** The only door-level architecture a small team can ship without venue-side hardware or proprietary surveys is **fiducial-anchored VIO**: print NaviLens-style codes / QR / AprilTags at key destinations for instant *absolute* sub-meter pose + bearing, and let ARKit world-tracking dead-reckon between tags (re-anchoring every ~10–20 m to stay under the drift ceiling). NaviLens already proves this hits sub-1.5 m with *no GPS, WiFi, or Bluetooth* and reads from 60 feet across a 160° field ([AFB](https://afb.org/aw/march2023/navilens)). This is the unglamorous sticker-and-camera technique that outperforms GPS, VPS, and beacons on the precise job — and the infrastructure is *paper the team prints itself.*
- **The reading half (sign/room-number/menu/kiosk) solves the aiming problem, not the OCR problem** — "point roughly, and it finds and reads the text for you" — which is the actual bottleneck and the validated AI sweet spot.

Be honest about scope: door-level positioning at an *arbitrary* building you don't control and can't pre-map or instrument is the open research gap, not a solved feature. A credible product **owns the environment it instruments** (a campus, an airport wing, a transit corridor, a partner clinic network) and is explicit that arbitrary-venue precision is unsolved. That is also the path to the institutional/sponsored deployment model that actually funds this category (the way *free Aira airport zones* drive real adoption, not retail subscriptions).

What this wedge deliberately does **not** try to own: obstacle avoidance (the cane has it), street-crossing safety decisions (the cane, the human, and APS/AVAS infrastructure have it), and "replace the cane/dog" (the community has explicitly rejected it).

---

## 6. A needs-grounded reframing of purpose and a prioritised roadmap

### Reframed purpose

Citrus Squad should stop being **"a haptic navigation belt that tells blind people which way to move"** and become:

> **A cane-companion orientation aid that gets you the last 50 feet to a specific door, pole, or counter, reads the world's text on demand, and helps you build your own mental map — while you, your cane, and your ears stay in charge.**

The shift is from *decider* to *informant*; from *replacing* the cane to *assuming it is present and owns the next meter of ground*; from a feature fusion to a single owned problem.

### Roadmap, tied to the existing tiered voice / vision / belt architecture

**Phase 0 — Before another line of feature code (non-negotiable).** Bring blind travelers and an O&M instructor into the room as co-designers and testers. Get the belt onto a real body for real walks. Resolve the mirrored-band bug as *blocking*. This is not bureaucracy; it is the top abandonment predictor, and a hackathon timeline is not an excuse the literature accepts.

**Phase 1 — Make the voice/vision tier the product, and make it honest.**
- Promote **voice-set destination + on-demand sign/scene reading** to the headline. This targets the real top needs and leans on the phone the user already owns.
- Add an **active re-aim loop** ("I can't see the text clearly — pan left") instead of confident hallucination on the blurry, low-light, off-frame photos blind users actually take.
- Add **calibrated uncertainty** to every spatial/distance claim and a **one-tap human-escalation path** (Be My Eyes / Aira-style) for high-stakes reads (meds, money, addresses, "is this the right door").
- Actually run the Claude/vision tier on device, benchmark its hallucination rate, and either earn the claim or drop it. Rotate any exposed key.

**Phase 2 — Build the last-50-feet wedge.** Fiducial-anchored VIO for door-level final approach in *instrumented* environments. Be explicit and unembarrassed about the scope boundary. Pursue a sponsored/institutional deployment (a building, a transit partner) over a retail belt.

**Phase 3 — Demote the belt to what the evidence supports: a *directional confidence* accessory, not a safety device.** The feelSpace naviBelt evidence genuinely backs torso haptics for *direction* — intuitive, hands-free, ears-free, and its biggest measured effect was on *confidence* within one week ([PMC8587958](https://pmc.ncbi.nlm.nih.gov/articles/PMC8587958/)). Keep that, and *only* that. The same evidence sets the hard limit: blind users warn it is "not exact enough" for safety-critical fine positioning. The belt may whisper "your route bears left"; it may never decide an obstacle steer.

### What to STOP doing (explicitly)

1. **Stop issuing directive safety output.** `check_path` and the belt must move from "step left / step right / stop / StepLeft(paces:2)" (deciding) to "person close, center-left" (informing). Kill the directive action layer. The wearer is the decision-maker, full stop. This is simultaneously the regulatory off-ramp, the liability defense, and the design blind users trust.
2. **Stop calling the LiDAR→belt loop a "safety reflex"** and stop having the voice tool assert a "LiDAR-confirmed safe direction." Phone-LiDAR proximity is advisory context that cannot see curbs, drop-offs, stairs-down, head-height, glass, or traffic — and Apple itself says not to rely on it for safety.
3. **Stop routing any safety-critical alert over no-ack UDP.** Until the belt has a *liveness return path* surfaced through a second channel — so a dead belt feels different from a clear path — it cannot honestly call itself a safety device.
4. **Stop framing obstacle detection as the headline.** It duplicates the cane and earns the drawer.
5. **Stop marketing it as "an orientation and mobility aid for the blind."** That exact phrase is the FDA device-classification trigger (BrainPort precedent).
6. **Stop positioning it as a cane replacement anywhere in the *product*** (not just the pitch deck). Add an onboarding statement and a persistent reminder that it supplements and never replaces the cane/dog, and assume the cane is in use — as Aira's terms require.

---

## 7. Design principles drawn from the abandonment literature

These are the rules that keep this out of the drawer. Each is grounded in the evidence above.

1. **Describe, don't decide — end to end.** Route every safety-critical judgment to the cane, the guide dog, O&M skill, or a trained accountable human. AI describes; the wearer decides. This is the convergence point of the abandonment, liability, regulatory, and community-trust evidence — they all point the same way.

2. **Minimize conveyed information.** Terse (5–7 word), event-triggered, priority-ranked, interruptible output. Latency >1s and verbosity are documented abandonment causes; "only tell me what I'm interested in." Aggressive data reduction is the opposite of the engineering instinct, and it is what killed every sensory-substitution device that didn't do it.

3. **Protect hands and ears as scarce safety resources.** Never occupy the cane/dog hand; never mask traffic, EVs, cyclists, or echoes. Prefer bone-conduction or open-ear; reserve the audio channel for *content* and a haptic channel for *direction only*. One channel, one language — never three jobs on four motors.

4. **Design for doubt and the verification gap.** The model must be able to say "I can't tell from this angle." Surface uncertainty audibly, provide non-visual verification paths (re-aim loop, multi-sample cross-check, human handoff), and never let fluent TTS manufacture false confidence — overtrust is engineered in unless you engineer it out.

5. **Augment the cane; assume it is present.** The cane owns the next ~1.2 m of ground; do not duplicate it, do not interfere with its tactile feedback or echolocation, do not pull attention off the arc. Position for the genuine cane gap (overhead/approaching/last-50-feet/reading), not the solved one.

6. **Co-design with blind users from day one; bundle real training.** Three of four abandonment predictors are about user involvement and fit. Lack of training is a named predictor and the most commonly omitted feature. "Nothing about us without us" is a build constraint, not a slogan — and the community polices its misuse.

7. **Design for the modal user, not the forum power user.** Support residual sight (contrast, magnification, visual overlays) and the elderly, late-onset, hearing-impaired, neuropathy-prone, phone-averse, stigma-sensitive majority — or honestly narrow the claim to the user you actually serve. Don't make a late-blind user publicly "become blind" before they'll accept the tool.

8. **Earn the "better-than-free" bar, and avoid the orphan trap.** You compete with Seeing AI, Lookout, VoiceVista, Apple's built-ins, and a $40 cane that needs no charge or network — and against OrCam's grave. Lean on the phone the user owns, keep the time-critical path offline and low-power, avoid hard dependence on one proprietary cloud, and commit credibly to longevity. Blind users have been burned by Soundscape, BLAID, OrCam, and Sunu; durability and an open, exportable data layer are how you build the trust the category has squandered.

9. **Measure retention, not demo wow-factor.** The benchmark for "valuable" is not "does it work on stage" but "would a blind traveler — including a low-income, partially-sighted, older one — still be using this in six months on the device and data plan they actually have." Track 30/90/365-day retention as the primary KPI. Cool factor can actively *reduce* adoption.

---

**Bottom line.** Citrus Squad's instinct to keep AI off a deterministic, ears-and-hands-free channel is genuinely good and genuinely rare — keep it. But the belt is not the value, the obstacle-avoidance framing re-solves the cane's job while leaving the face exposed, the directive steer/stop output is the harm the community names and the line the regulators draw, and no blind person has been in the room. Demote it to an honest research prototype, gut the directive safety output, put the cane back at the center of both the code and the copy, point the voice/vision tier at the last-50-feet and reading wedge, and bring in blind co-designers before it goes one step further. The meaningful product hiding inside this one is a humble cane companion that gets you to the actual door and reads the world's text — not a savior gadget that decides where a blind person steps.
