# SWIFT.md — How we write Swift in this repo

This is the working rule set for any Swift or SwiftUI code in this repo. Claude reads it before writing Swift. Teammates can read it once and then forget it, because the rules match what a careful iOS engineer already does.

It pairs with [`IOS-APP-PLAN.md`](IOS-APP-PLAN.md), which is the architecture. This file is the craft.

Status: this is the iOS-native track. It applies once the team confirms Swift at the alignment meeting. If the team picks Expo, this file goes dormant and we follow the React Native conventions in `CONTRIBUTING.md` instead.

## Toolchain and target

- **Swift 6 language mode** with strict concurrency checking on. Treat every concurrency warning as an error to fix, not noise to silence.
- **Minimum deployment iOS 17.** The only device that ships at the demo is Sam's iPhone 15 Pro Max on iOS 27 beta, so there is no reason to support older OSes. iOS 17 unlocks the Observation framework (`@Observable`) and the modern Swift concurrency surface we rely on. The sister `wand-phone-probe` targets iOS 16 for portability, but the production app does not need that.
- **Xcode 16 or newer.** Build with the demo phone as the run destination, not the simulator, because the whole app is sensors and radios that the simulator cannot fake.
- **XcodeGen for the project file.** `Project.yml` is the source of truth, the `.xcodeproj` is generated and gitignored (the repo `.gitignore` already excludes it). Regenerate with `xcodegen generate` after touching `Project.yml` or adding files. This mirrors the probe and keeps merge conflicts out of the project file.

## Concurrency

This is the area that separates clean iOS code from code that crashes at the demo. Follow it exactly.

- **async/await for everything asynchronous.** No completion-handler pyramids in new code. Wrap a legacy delegate or callback API in a `withCheckedContinuation` or an `AsyncStream` at the boundary, then everything above that line is async.
- **`@MainActor` for anything that touches UI or `@Observable` view state.** Views, view models, and the app model are main-actor isolated. Never mutate published state off the main actor.
- **Actors for shared mutable state that is not UI.** The LC2 transmitter and any packet queue live in an `actor`, so the 100 ms heartbeat and the route engine can both touch the send buffer without a data race.
- **`Sendable` is not optional.** Every type that crosses a concurrency boundary conforms to `Sendable` or is an `actor`. If the compiler complains, fix the type, do not add `@unchecked Sendable` unless you can write one sentence proving why it is safe.
- **No `DispatchQueue` in app logic.** The only acceptable use is inside a service wrapper that bridges a framework delegate (CoreLocation, AVFoundation) back onto the main actor, and even then prefer hopping with `await MainActor.run` or marking the delegate method's hop explicitly.
- **Timing loops use a dedicated `Task` with a clock**, not `Timer`. The heartbeat is `Task { while !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)); ... } }`. Cancel the task to stop the loop. `Timer` ties you to a run loop we do not want to depend on.
- **Capture lists are mandatory in escaping closures.** `[weak self]` for anything that outlives the call, then `guard let self else { return }`. A retain cycle on a service that owns a socket is a slow leak that surfaces as a dead radio mid-demo.

## State and views

- **`@Observable` from the Observation framework, never `ObservableObject` / `@Published`.** It is iOS 17+, it is faster, and it removes the Combine boilerplate. The probe uses `ObservableObject` because it targets iOS 16; the production app does not copy that.
- **One app model, owned at the app entry, passed down with `@Environment`.** Sub-features get their own smaller `@Observable` models when they have real state. A view that only displays data takes a plain value, not a model.
- **Views are dumb and small.** A view lays out data and forwards user intent to a model. No networking, no geometry math, no packet encoding inside a `body`. If a view file passes ~150 lines, split it.
- **Value types by default.** `struct` for models, events, packets, and route data. Reach for `class` or `actor` only when you need reference identity or isolation (services, the app model).
- **`@State` for view-local state, `@Bindable` for two-way binding into an `@Observable` model.** Do not reach for global singletons to share state between views.

## Errors and optionals

- **No force unwrap (`!`) and no `try!` in committed code.** Not on optionals, not on dictionary lookups, not on URL construction. The one tolerated exception is a compile-time constant you control, like a hardcoded resource name, and even then prefer `guard`.
- **`guard let ... else { return }` for early exits.** Keep the happy path un-indented.
- **Typed, meaningful errors.** Define an `enum` conforming to `Error` per subsystem (`DirectionsError`, `TransmitError`). Throw those, do not throw strings or stringly-typed `NSError`.
- **Fail loud in development, fail safe in the field.** A bad packet during dev should assert. The same code path in the running app drops the packet, logs it, and keeps the heartbeat alive. The demo failure modes in `docs/06-failure-modes.md` are the contract: silence beats a stale or wrong cue.

## Naming and layout

- **Follow the Swift API Design Guidelines.** Methods read as phrases at the call site. Booleans read as assertions (`isConnected`, `hasRoute`). No Hungarian prefixes, no `m_`, no abbreviations that are not industry standard (`url`, `id`, `gps` are fine).
- **One primary type per file**, named after the type. Small related helpers can share the file.
- **`// MARK: -` sections** to group properties, lifecycle, public methods, and private helpers. Keep them in that order.
- **Group files by feature, not by kind.** `Routing/`, `Networking/`, `Sensors/`, `Replay/`, `UI/`. Do not make a flat `Models/` `Views/` `Services/` split; it scatters one feature across three folders.

## Frameworks and platform

- **Networking is the `Network` framework (`NWConnection`), not `URLSession` for the UDP path and not a third-party socket library.** UDP to the ESP32 over Wi-Fi or the phone hotspot. `URLSession` is fine for the one Google Maps Directions HTTPS call.
- **Sensors reuse the probe's shape.** `CLLocationManager` for heading and GPS in one service, `CMMotionManager` for accel and gyro. The probe's `LocationHeadingService` and `MotionService` are proven on the demo phone; port them, do not reinvent them.
- **Logging is `os.Logger`, not `print`.** One `Logger` per subsystem with a clear category. `print` is acceptable only in a scratch spike on a personal branch.
- **Permissions are declared in `Info.plist` with honest usage strings**, the way the probe declares location, motion, and camera. Missing a usage string is an instant crash on first access.

## Accessibility

The product serves blind and low-vision wearers, so the operator UI we build leads by example.

- **Dynamic Type** on every text label. No fixed font sizes that break at large accessibility settings.
- **VoiceOver labels** on every control and every status indicator. A color-only status (green dot for connected) needs a label that says "connected."
- **Haptics through Core Haptics** when the control UI needs to confirm an action on the demo phone, kept distinct from anything that would be confused with a belt cue.

## Testing

- **Test the pure logic, skip the glue.** The bearing-to-quadrant geometry and the LC2 packet codec are pure functions with no sensors or radios. They get unit tests. A `CLLocationManager` wrapper does not; you verify that on-device by hand.
- **Swift Testing (`import Testing`, `@Test`) for new tests.** XCTest is fine if a teammate is faster in it. Do not mix styles inside one file.
- **A golden-vector test for the packet encoder.** Given a known event and quadrant, assert the exact bytes match `docs/03-protocol.md`. This is the single most valuable test in the repo, because a wire-format bug is invisible until the belt does the wrong thing.

## Formatting and lint

- **SwiftFormat and SwiftLint, both with a checked-in config**, run before opening a PR. Default rule sets are fine for a hackathon; do not spend the night tuning lint rules.
- **Four-space indentation, no tabs. Trailing commas in multiline collections.** Let the formatter own the rest so nobody argues about it in review.

## Git hygiene for Swift specifically

- **Never commit `xcuserdata/`, `DerivedData/`, the generated `.xcodeproj`, or `.swiftpm/`.** The repo `.gitignore` covers these, so the practical rule is: if XcodeGen made it, do not commit it. Commit `Project.yml` and `Sources/`.
- **Branching and PRs follow `CONTRIBUTING.md`.** Swift adds nothing new there.

## Voice

Any prose Claude writes into Swift docs, READMEs, or long comments follows the repo voice rules in `CLAUDE.md`. Plain headers, no em dashes in prose, write like a sharp teammate. Code comments explain why, not what; the code already says what.
