# Co-Design Session Plan (Phase 0)

The one thing the research says to do before writing the final-approach beacon or trusting any of this
in front of a blind traveler. Short and runnable on purpose.

**Why this is first, not last.** Three of the four statistical predictors of assistive-tech abandonment
are about process, not capability: the user's opinion was not in the design, the device was adopted too
casually, and the user's real needs were not the ones solved. "Nothing about us without us" is a build
constraint here, not a slogan. One good session changes what we build more than another week of code.
See [`BLIND-NAVIGATION-NORTH-STAR.md`](BLIND-NAVIGATION-NORTH-STAR.md) and
[`LAST-50-FEET-SCOPING.md`](LAST-50-FEET-SCOPING.md) §8.

## Who to bring in (and pay)

This is labor, not a favor. Compensate participants at a real rate.

- **2–3 blind / low-vision travelers, deliberately mixed**, not just one young screen-reader power user:
  - at least one **white-cane** user, and if possible one **guide-dog** user;
  - at least one **older, late-onset, low-vision** person, because that is the modal user (most "blind"
    people retain usable vision and are 65+); ask about **hearing** too;
  - a spread of **congenitally vs late blind** (they build spatial maps differently).
- **One certified O&M instructor (COMS).** They sanity-check safety, the training burden, and whether
  "augment the cane" actually holds.
- Recruiting channels: a local **NFB or ACB chapter**, a **VA blind-rehab** or state vision-services
  program, a **Lighthouse / Society for the Blind**, or **university disability services**.

## The stance (read this before you walk in)

They are the experts in the room; we observe and ask. Do not pitch, do not demo to impress, do not ask
"isn't this cool?" Ask "what is hard about this today?" Watch more than you talk. Expect to hear that
parts of our plan solve a problem they do not have — that is the point of going.

## The session (~90 minutes)

1. **Open interview (15 min).** In their own words: how do you get the last few meters to a specific
   door, counter, or bus pole today, and how do you read a sign, room number, or label in the wild?
   Where does it fail? Do **not** lead toward our features.

2. **Contextual walk (20 min).** Watch them navigate to a door and read its sign with their **own**
   tools. Do not help. Note exactly where the cane, the dog, and their hearing do the work — that is
   the territory we must not duplicate or interfere with.

3. **Wizard-of-Oz the beacon (25 min) — the key method.** Run the detection foundation (Diagnostics →
   Scan markers on a printed sheet), but a facilitator drives a **fake** "getting-warmer" cue by hand
   (a second person speeding up a tone, or a slider) so we test the *grammar* before building it. Try a
   few styles — warmer/colder cadence, the on-axis "body becomes the pointer" tone, a coarse belt
   bearing tap. Let them tell us which actually conveys "the door is there, slightly left, close," and
   which is noise. **This is what decides the beacon spec.**

4. **The honest reader (10 min).** Have them use Read Sign on a real sign (the printed `ROOM 214`).
   Does the aim-coaching help or frustrate? Does the high-stakes hedge feel honest or naggy? Does
   "double-check with someone you trust" read as useful or as a dead end?

5. **Describe vs decide (5 min).** Play the old `check_path` line ("step left / stop") against the new
   one ("there's more room on your left"). Confirm with real users that informing beats commanding.

6. **Form factor + stigma (10 min).** The chest phone and the vibrating belt: would you wear this in
   public? Where should the audio go — and confirm the **open-ear / bone-conduction** constraint, since
   a speaker tone that masks traffic and EVs is a safety problem, not a preference.

## What to watch for (the abandonment signals)

- Does anything compete for the **cane / dog hand** or mask **traffic, EVs, echoes**?
- Cognitive load — is it one more thing to attend to mid-walk?
- Stigma — does the hardware mark them out?
- The honest one: would they still use this in **six months**, on the phone and plan they actually have?

## What to bring

The phone with the current build; several printed markers (`test-markers.html`, 4–6 per spot); a real
sign to read; a way to fake the beacon (a second phone or a person); consent forms and compensation; an
audio recorder (with permission) and a dedicated note-taker so the facilitator can focus on the person.

Two quick on-device calibrations to knock out the same day, with a participant: the **`lidarBandsMirrored`**
check (hold a target hard left, confirm the left side reports it) and the **anchor-bearing** side check
(same, for a scanned marker) — both must be confirmed before any directional cue is trusted.

## What we decide afterward

Freeze (or rewrite) the **beacon grammar** from what worked in step 3; lock the **audio channel**;
decide honestly whether the **belt** earns its place or is demoted to an optional bearing accessory; set
the **retention metric** (would a real traveler keep it at 30 / 90 / 365 days). Then, and only then,
write the beacon. The detection foundation is already in; this session writes the spec for what sits on
top of it.
