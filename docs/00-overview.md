# 00 — Overview

## What we are building

**WAND** (Wearable Assistive Navigation Device) is a haptic navigation belt for blind and low-vision wearers. A chest-mounted phone reads Google Maps walking directions, computes the body-relative bearing of the next turn using the phone's compass and IMU, and fires the matching quadrant on a four-servo belt as a discrete tap.

If a Coral Dev Board vision layer ships, it adds a person-in-path safety signal: when the camera detects someone walking into the wearer's path, the belt fires a sustained tap-train on the relevant quadrant.

The pitch is one sentence: "WAND tells you which way to turn, by tapping you in the direction you should go."

## Track

**Ddoski's Lab** (science and engineering). Hardware prototype with on-device AI. The judging weight is technical depth and real-world application.

## What it is not

- Not a cane replacement. Cane catches things at foot level; WAND adds upper-body and navigation awareness on top.
- Not a clinical device. No IP rating, no medical claims, no EMF certifications.
- Not voice or audio. Haptic only.
- Not indoor navigation. Outdoor GPS routes only.

## Current direction (subject to alignment meeting)

Frontrunner is WAND as described. The alignment meeting at the start of the hack confirms direction and may pivot. Until that happens, every spec in this folder is "current best plan," not "locked."

Locks in place (do not reopen without team consensus):

- **Form factor.** Belt with four chest/torso servos (Far Left, Left, Right, Far Right). One ESP32 drives them.
- **Phone-IMU heading.** The phone reads its own compass and computes body-relative bearing to the next turn. No belt-side IMU.
- **Replay-first demo.** The demo plays back a pre-cached route, not a live one. Survives venue Wi-Fi and GPS issues. Live outdoor demo is a bonus, not a baseline.
- **Team-member wearer.** A teammate wears the belt for the demo. A judge can wear it if they ask, but consent and safety stay off the critical path.

## Why this design

The shortest version: most assistive haptic projects either build a vibration vest for obstacle avoidance (solved problem; cane does it better) or build a phone app that talks directions (solved problem; Google Maps does it). The interesting space is in between — directional cues that don't require listening to headphones in traffic. That is the niche WAND fits.

Tier-3 vision adds a "what does the camera see right now" signal that a cane cannot deliver. It is conditional because the team is learning Coral Edge TPU from cold; if the pre-event learning sprint slips, vision cuts first.

## Status

- **Idea direction:** WAND (frontrunner, confirmed at alignment meeting).
- **Stack:** open between Expo (React Native) and native iOS (Swift). Native iOS already proven viable on the demo phone (see [`10-validated.md`](10-validated.md)).
- **Demo phone:** iPhone 15 Pro Max running iOS 27.0 beta. Phone capabilities verified.
- **Hardware:** four hobby servos, one ESP32, one Coral Dev Board, all in hand.
- **Hack window:** Saturday June 20, 11:00 AM through Sunday June 21, 11:00 AM. 24 hours.
