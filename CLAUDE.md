# CLAUDE.md — Citrus Squad × Berkeley AI Hackathon 2026

Auto-loaded by Claude Code. Read first every session.

## What this repo is

Citrus Squad's code repo for the Berkeley AI Hackathon 2026 (June 20-21, MLK Jr. Building, UC Berkeley). This is the production repo. Code that ships at the demo lives here.

The planning playbook is a separate repo: [`citrus-squad-bible`](https://github.com/Sam-T-G/citrus-squad-bible). Treat it as the source of truth for project direction, ideation, timeline, pitch craft, and (if WAND is the chosen idea) the design spec under `docs/20-` through `docs/24-`.

## Project direction

Open as of repo creation (June 20, 2026). Frontrunner is WAND (haptic navigation belt for blind and low-vision wearers). The team confirms direction at the session-start alignment meeting. Until then, do not assume scope.

## Stack

Not yet picked. The §6.5 alignment meeting in the bible picks one of:

- **Expo** (React Native + TypeScript)
- **Native iOS** (Swift + SwiftUI)

Native Android dropped out per the bible's build log iter 24 (demo phone is an iPhone). Wait for the stack decision before scaffolding.

## Voice rules

Apply Samuel's standing writing voice to any prose Claude writes into this repo.

- No em dashes in prose. Restructure or split. Structural dashes in headings and label-value lists are fine.
- No "this isn't X, it's Y" contrast patterns.
- No AI tells: `delve`, `tapestry`, `at its core`, `in conclusion`, `it is worth noting`, `landscape of`, `realm of`, `navigate the complexities`.
- No corporate jargon (`leverage`, `end-to-end`, `deliverable`, `cutover`).
- Plain English section headers.
- Write like a sharp teammate, not a consultant deck.

## Working norms

- **Read the bible first.** Before writing code for a feature, check the bible's matching design doc. If the doc says one thing and the code says another, the doc wins until Sam confirms a scope change.
- **Branching follows `CONTRIBUTING.md`.** Personal branches use `sam/`, `cole/`, `josh/`, `angelo/` prefixes; feature branches use `feat/<topic>`.
- **No `node_modules/` or `xcuserdata/` in commits.** The `.gitignore` covers both stacks.
- **Commits are imperative, present tense.** "Add heading service" not "Added heading service."

## Free / ask first / never

**Free:** edit anything in this repo. Create branches. Push your own branches. Open PRs. Run the dev server. Install dependencies into a personal branch.

**Ask first:** merge into `main` without a teammate skim. Add a new top-level directory once the stack is picked. Change the `.gitignore` in a way that excludes something already committed.

**Never:** push to `main` directly once a teammate has an open branch. Force-push to `main` ever. Commit secrets, API keys, signing certs, or `.env*` files.

## Hard rules during the hack window

- Hack window opens **Saturday June 20 at 10:00 AM** and runs 24 hours.
- Event window closes **Sunday June 21 at 6:00 PM** after judging.
- Devpost submission deadline per the bible's `docs/14-timeliness-and-pacing.md`. Check that doc before assuming the submit-by time.
- Demo phone is Sam's iPhone 15 Pro Max running iOS 27.0 beta. Free-tier signing covers the hackathon window (cert expires June 26-27).
