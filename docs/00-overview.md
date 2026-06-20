# 00 — Overview

## What we are building

**Citrus Squad** (Wearable Assistive Navigation Device) is a haptic navigation belt for blind and low-vision wearers. A chest-mounted phone reads Google Maps walking directions, computes the body-relative bearing of the next turn using the phone's compass and IMU, and fires the matching quadrant on a four-servo belt as a discrete tap.

The same phone also senses what is ahead. Its LiDAR scanner reads proximity, so the belt fires a sustained tap-train when something is close on a given side. The camera adds a person-in-path signal on top as a stretch. Both run on the phone, so no extra hardware rides on the belt. The design is in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md).

The pitch is one sentence: "Citrus Squad tells you which way to turn, by tapping you in the direction you should go."

## Track

**Ddoski's Lab** (science and engineering). Hardware prototype with on-device AI. The judging weight is technical depth and real-world application.

## What it is not

- Not a cane replacement. Cane catches things at foot level; Citrus Squad adds upper-body and navigation awareness on top.
- Not a clinical device. No IP rating, no medical claims, no EMF certifications.
- Not voice or audio. Haptic only.
- Not indoor navigation. Outdoor GPS routes only.

## Current direction (subject to alignment meeting)

Frontrunner is Citrus Squad as described. The alignment meeting at the start of the hack confirms direction and may pivot. Until that happens, every spec in this folder is "current best plan," not "locked."

Locks in place (do not reopen without team consensus):

- **Form factor.** Belt with four chest/torso servos (Far Left, Left, Right, Far Right). One ESP32 drives them.
- **Phone-IMU heading.** The phone reads its own compass and computes body-relative bearing to the next turn. No belt-side IMU.
- **Replay-first demo.** The demo plays back a pre-cached route, not a live one. Survives venue Wi-Fi and GPS issues. Live outdoor demo is a bonus, not a baseline.
- **Team-member wearer.** A teammate wears the belt for the demo. A judge can wear it if they ask, but consent and safety stay off the critical path.

## Why this design

The shortest version: most assistive haptic projects either build a vibration vest for obstacle avoidance (solved problem; cane does it better) or build a phone app that talks directions (solved problem; Google Maps does it). The interesting space is in between — directional cues that don't require listening to headphones in traffic. That is the niche Citrus Squad fits.

The phone's LiDAR and camera add a "what is right in front of me" signal that a cane cannot deliver at upper-body height. Proximity from LiDAR is a base layer because it needs no new hardware and works in any lighting. Person-in-path from the camera is a stretch on top. The Coral Dev Board, which an earlier plan used for this, is now an optional sponsor-angle stretch only.

## Status

- **Idea direction:** Citrus Squad (frontrunner, confirmed at alignment meeting).
- **Stack:** native iOS Swift, confirmed at the alignment meeting. The base app is scaffolded and compiling in [`ios/`](../ios/). Proven viable on the demo phone (see [`10-validated.md`](10-validated.md)).
- **Demo phone:** iPhone 15 Pro Max running iOS 27.0 beta. Phone capabilities verified, LiDAR and camera included.
- **Hardware:** four hobby servos and one ESP32 drive the belt. The phone's own LiDAR and camera do the sensing. One Coral Dev Board is in hand and held in reserve for the optional sponsor stretch.
- **Hack window:** Saturday June 20, 11:00 AM through Sunday June 21, 11:00 AM. 24 hours.
