# HANDOFF — Citrus Squad phone app (Swift)

For the agent picking up the iOS app once the base structure compiles. Read this, then build in the order below. The design work is done; this is the runbook to implement against it.

Branch: `sam/ios-app-base`. The base was scaffolded here and this is where the phone-app work continues. Keep all code under `ios/Sources` and `ios/Tests`.

## Read order

1. This file.
2. [`docs/11-phone-app-design-spec.md`](docs/11-phone-app-design-spec.md) — the build contract. The bearing-to-bytes table and the ownership calls live here.
3. [`IOS-APP-PLAN.md`](IOS-APP-PLAN.md) — module map.
4. [`SWIFT.md`](SWIFT.md) — craft rules. Read before writing any Swift.
5. [`docs/03-protocol.md`](docs/03-protocol.md) and [`docs/04-phone-side.md`](docs/04-phone-side.md) — wire format and product behavior.
6. [`docs/12-perception-and-safety-design.md`](docs/12-perception-and-safety-design.md) — the LiDAR + camera safety tier. Read this before extending `DepthService` past sensing. It resolves how depth becomes a belt cue, the safety-over-direction arbitration, and the demo and thermal hardening.

## Where the base left off

Snapshot of `ios/` at handoff time. It is scaffolded but not yet committed (`git status` shows `?? ios/`).

Present:

- `ios/Project.yml` — XcodeGen source of truth. iOS 17, Swift 6, strict concurrency complete, team and bundle id set (`com.samuelgerungan.CitrusSquad`). Declares a `CitrusSquadTests` target.
- `ios/Sources/CitrusSquadApp.swift` — `@main`, shows `ControlPanelView()`.
- `ios/Sources/Info.plist` — three permission strings (location, motion, camera).

Does not compile yet, by design. Two reasons:

- `CitrusSquadApp` references `ControlPanelView`, which does not exist.
- `Project.yml` declares a `CitrusSquadTests` target with a `Tests/` source path that does not exist.

Not built yet: no `AppModel`, no services, no `Routing` / `Networking` / `Sensors` / `Replay` / `UI` folders.

## First five moves to a green build

Do these in order. They get the project compiling and runnable before any feature work.

1. **Create the feature folders** under `ios/Sources`: `Routing/`, `Sensors/`, `Networking/`, `Replay/`, `UI/`. Group by feature, not by kind (per `SWIFT.md`). `createIntermediateGroups` is already on in `Project.yml`.
2. **Add `AppModel`** at `ios/Sources/AppModel.swift` as `@MainActor @Observable final class`. Own it at the app entry in `CitrusSquadApp` and inject with `.environment(...)`. `ControlPanelView` reads it with `@Environment`.
3. **Add a minimal `ControlPanelView`** in `ios/Sources/UI/` so the missing symbol resolves and the app runs. A status placeholder is enough for now.
4. **Create `ios/Tests/`** with one real test file so the `CitrusSquadTests` target resolves. The `LC2Packet` golden-vector test once the codec exists, or a trivial passing test as a placeholder until then. Regenerate the project: `xcodegen generate`.
5. **Add `CitrusSquadConfig.swift`** with the constants from `docs/11`. Every module references it. No magic numbers scattered across files.

After these five, the app builds and runs on the demo phone. Then feature work begins.

## Build in milestone order

Each maps to a milestone in `docs/04-phone-side.md` and a done-bar in `docs/11`. Each step ships on its own and de-risks the next.

- **M0 — radio first.** `LC2Packet` and `LC2Transmitter` (`Networking/`). Fire a hardcoded turn-left packet at the ESP32 on the 100 ms heartbeat. Golden-vector test green. Belt twitches on command. This proves the link, the highest-risk unknown, before any routing exists.
- **M1 — heading.** Port `LocationService` for heading (`Sensors/`), apply the calibration offset. Body heading reads within ±10° while the phone is held still.
- **M2 — calibration.** Calibrate button in `ControlPanelView` records the offset. Two presses produce offsets within 2°.
- **M3 — routing math.** GPS plus `DirectionsClient` with a cached route. `Bearing` math matches a hand-computed sample within 1°.
- **M4 — quadrant mapper.** `quadrantFor` using the table in `docs/11`. All eight cardinal directions pass. Hysteresis holds at boundaries.
- **M5 — the ship line.** `RouteReplayer` plus a recorded route. Three clean walks of the demo loop with every turn cue firing on the correct side. This is "shippable in the demo."
- **M6 — optional bonus.** Step counting between fixes, fall detection, auto-recalibration on held-still.

If time runs short, the cut line is after M5's replay path. Replay plus a working belt is a complete story. Live Maps is the stretch the pitch discloses.

## Gotchas to handle, not rediscover

These are the traps the design pass already found. Each has a fix in `docs/11`.

- **Do not paste the probe code.** `wand-phone-probe`'s services are iOS-16 `ObservableObject` / `Combine` / `DispatchQueue`. Port the sensor configuration (the accuracy, the `headingFilter`, the `0.02` interval), rewrite the shell to `@Observable` plus strict concurrency. See `docs/11` "Porting the probe."
- **Camera permission describes a feature that does not exist.** `NSCameraUsageDescription` in `Info.plist` and `Project.yml` talks about a LiDAR obstacle sensor. Tier-2 does not use the camera. Recommend removing it so the demo shows one fewer permission prompt. See `docs/11` "Permissions."
- **Sequence byte is the transmitter's.** Not the route engine's. It increments every heartbeat tick, idle included, and wraps at 255.
- **Hysteresis is `RouteEngine` state.** `Bearing` stays pure. The deadband needs the previous quadrant.
- **One bearing-to-bytes table.** It is in `docs/11`. Use it verbatim. Do not re-derive the mapping from `03` and `04` separately, that is how the two drift.

## Branch and coordination

- Work on `sam/ios-app-base`. Code under `ios/Sources` and `ios/Tests` only.
- The design docs (`docs/`, root markdown) are the contract. If a spec is wrong or blocks you, flag it in the PR description or team chat. Do not silently fork the contract in code.
- Commits are imperative present tense per `CONTRIBUTING.md`. Squash-merge to `main` with a teammate skim.
- Run `xcodegen generate` after any `Project.yml` change or file add. Never commit the generated `.xcodeproj` (it is gitignored).

## Definition of done for the phone app

M5 green: the replay demo drives the belt, every turn cue fires on the correct side across three clean walks, there are no strict-concurrency warnings, and the `LC2Packet`, `Bearing`, and `RouteEngine` tests pass.
