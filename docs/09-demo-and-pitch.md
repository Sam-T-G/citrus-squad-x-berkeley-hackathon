# 09 — Demo and pitch

## The demo

A teammate wears the belt and the chest-mounted phone. The pitch person stands next to a 30-meter demo lane (taped on the floor if needed) and narrates while the wearer walks. The phone plays back a pre-cached route. The belt taps the wearer on each turn cue. The wearer responds.

### The 30-second beat

```
[Pitch person] "Citrus Squad tells you which way to turn, by tapping you in the direction
                you should go. Imagine walking through a city without being able
                to look at your phone."
[Wearer at lane start] Press Calibrate. Confirmation flash. Walking starts.
[At first turn, ~10 m in] Belt taps Right side. Wearer turns right.
[At second turn, ~20 m in] Belt taps Left side. Wearer turns left.
[At lane end] Belt sweeps left-to-right. Wearer stops.
[Pitch person] "That's it. The belt sees the turn coming, computes which way
                the wearer's body is actually facing, and taps the right side
                without ever needing audio or a screen."
```

### The safety beat (base, ~20 seconds)

Between the two turns, an operator steps into the lane in front of the wearer. The phone LiDAR reads the closing distance and the belt fires the sustained tap-train on the side the obstacle is on. The wearer stops. The pitch person explains that the phone is sensing what is ahead, not just reading a map.

This is a base feature now, not a conditional one, because it runs on the phone's own LiDAR with no extra hardware and works in any lighting. Script it like the turns: the operator approaches on a marked line from a clean start position, on the wearer's cue. If the camera person-detection stretch shipped, the pitch person adds the word "person"; if not, the LiDAR still carries the beat as "obstacle detected." Rehearse it, and if it ever flakes in a dry run, cut it per the common-failure rule below.

### Why replay, not live GPS

Live outdoor GPS is bonus. The replay-first demo:

- Survives venue Wi-Fi.
- Survives urban-canyon GPS errors.
- Is deterministic; every judge sees the same demo.
- Is faster: we can run three demos in 3 minutes instead of one walk-around outside.

Live GPS lives in the bonus pitch beat ("and yes, we walked an actual outdoor route with this; here is the video / here is the captured trace").

### Backup video

Recorded at H+22 (Sunday morning) before the dress rehearsal. 90 seconds. Shows the demo working end-to-end. Saved on the pitch person's laptop and on a phone.

The video plays if:

- The wearer is unavailable at the judge's turn.
- The belt is acting up.
- The judge has 30 seconds and we want the high-impact version.

The video is never the primary demo. It is the safety net.

## The pitch (3 minutes total)

### Opening (30 seconds)

State the problem. State who it's for. State the one-line solution.

> "Cane users get great obstacle avoidance at foot level. What they don't get is route guidance that doesn't require headphones blocking street sounds. Citrus Squad is a haptic belt that taps you in the direction your next turn is."

### Demo (90 seconds)

The 30-second beat above, walked live in front of the judge. If they have time, run it twice from different angles. If they only have 30 seconds, do the 30-second beat.

### Technical depth (45 seconds)

Pick the two most defensible technical claims and say them clearly:

- "The phone computes body-relative bearing using its own compass, so the cue is correct regardless of which way the wearer's body is facing."
- "The belt fires within 250 milliseconds of the cue being decided. We measured this on hardware."

Add the safety claim, which is now a base feature: "The same phone reads its LiDAR scanner to sense what is ahead, and fires a distinct danger pattern when something is close in the wearer's path. It works in any lighting because LiDAR is active infrared." If the camera stretch shipped, add that on-device Vision confirms it is a person.

### Closing (15 seconds)

State what you would do with another week. Show you have thought past the demo.

> "Next iteration: stairs and drop-off detection from the LiDAR depth map, semantic obstacle classes from the camera, and an integration with iOS Live Activities so the wearer's phone screen also shows the next turn."

## What the pitch deliberately does NOT do

- Does not oversell the assistive device pitch. We are not solving blindness. We are adding one signal cane users currently have to use audio for.
- Does not claim clinical testing. This is a hackathon prototype.
- Does not pitch market size. Judges have heard "$X billion accessibility market" 50 times today.
- Does not compare against a list of named competitors. Stay positive.

## Track positioning

**Ddoski's Lab** (science and engineering). The judging weight is technical depth and real-world application.

The technical-depth angle: two coordinated devices (phone + ESP32) talking a custom 4-byte protocol, with body-relative bearing math, on-device LiDAR depth sensing, safety-over-direction arbitration, and on-device Vision if the camera stretch ships. The phone does the sensing and the brain; the ESP32 does the deterministic actuation. We can articulate every link in that chain.

The real-world angle: the team-member wearer is the demo. We can describe what a real cane user gains from this signal. The framing is "supplement to the cane," not "replacement for it."

## Sponsor angles

Two real candidates:

- **Google.** Maps Directions API is a Google product and ships in the base. If the optional Coral Edge TPU stretch also ships, the Google angle gets stronger. Either way it is genuine and worth pitching to a Google judge.
- **Microsoft, Anthropic, or other AI sponsors.** Only if we end up integrating one of their APIs (we are not planning to as of repo creation). Do not retrofit a sponsor angle if it isn't real.

Side prizes are sponsored separately from the main track. Read the sponsor side-prize criteria at check-in and decide whether any are worth a 20-minute side conversation.

## Common pitch failures

A short list of things that lose pitches at hackathons; check the dry run against these.

- **The pitch is longer than 3 minutes.** Judges have 8 minutes per team in expo. Three minutes for pitch + demo + closing leaves 5 for questions.
- **The first 30 seconds doesn't say what the thing is.** If a judge has to wait until minute 2 to learn what Citrus Squad is, they have already wandered off mentally.
- **The wearer narrates instead of the pitch person.** The wearer's job is to walk and react. The pitch person's job is to talk.
- **The demo includes a fragile beat that has flaked even once in rehearsal.** Cut it. Demo what works.
- **The pitch person stops watching the wearer.** The wearer is the demo. The pitch person's eyes should follow them.

## Dry run schedule

Per [`07-timeline.md`](07-timeline.md), three dry runs in the H+22 to H+24 block. Each dry run:

- Pitch person reads from the script the first time.
- Three teammates play judges and ask one question each at the end.
- Record one dry run on the pitch person's phone. Watch it back together. Catch what reads as a stumble or an "uh."

The third dry run should be smooth. If it isn't, do a fourth.
