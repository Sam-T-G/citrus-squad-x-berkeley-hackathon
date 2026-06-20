# Contributing — Citrus Squad × Berkeley AI Hackathon 2026

Short rules so the four of us don't step on each other during a 24-hour hack.

## Branching

- `main` is protected by convention (no force push, no direct commits to main once anyone else has a branch open). Land via PR.
- **Personal branches**: prefix with your name. Use these for early exploration and anything you don't expect others to read yet.
  - `sam/<topic>`
  - `cole/<topic>`
  - `josh/<topic>`
  - `angelo/<topic>`
- **Feature branches**: when the work is shareable, rename or merge into a `feat/<topic>` branch.
- **Fix branches**: `fix/<topic>` for bug fixes during the hack.

Example flow: `git checkout -b sam/phone-imu-spike` → work for an hour → push → realize it's solid → open PR titled "Phone IMU heading scaffold" → squash-merge.

## Commits

- Present-tense, imperative mood. "Add heading service" not "Added heading service."
- One concern per commit if you can. Hackathon time means it's fine to bundle when it's faster.
- No "WIP" commits on `main`. WIP is fine on personal branches.

## Pull requests

- Tag at least one teammate to skim before merging into `main`. A two-minute look is enough. Block only on actual problems, not on style preferences.
- **Squash-merge** by default. Keeps `main` history readable when we look back during the pitch.
- Self-approve if no teammate is online and the change is small and obviously safe. Note in the PR description that it was self-approved.

## Where things go

Project direction is not locked yet. Until the team picks a stack, treat the repo as empty.

Once the stack lands:

- **Expo (React Native + TS):** standard Expo layout under `app/`, components in `components/`, services in `services/`. Don't check in `node_modules/` (already in `.gitignore`).
- **Native iOS (Swift):** an Xcode project at the root or under `ios/`. Don't check in `xcuserdata/`, `DerivedData/`, or `.xcworkspace/` (already in `.gitignore`).

## Spec questions

Look in the [`citrus-squad-bible`](https://github.com/Sam-T-G/citrus-squad-bible) first. If the bible doesn't answer it, the question is genuinely open. Either ask the team or write your assumption into the PR description and ship.

## When to stop and reconvene

- Two people are about to touch the same file in incompatible ways.
- A teammate's branch has been red for more than 30 minutes and you don't know why.
- An idea pivot that would change the README direction. Mention it in chat first.

Outside those cases, ship.
