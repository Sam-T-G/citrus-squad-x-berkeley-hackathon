# 10 — Validated capabilities

A short record of what the team has already verified on real hardware, before the hack starts. Each entry is a capability we no longer have to find out about Saturday.

## Demo phone (iPhone 15 Pro Max, iOS 27.0 beta)

Validated 2026-06-20 via a SwiftUI capability probe. All four phone-side capabilities the Citrus Squad scaffold relies on are confirmed working:

| Capability | API | Result |
|---|---|---|
| True heading from compass | `CLLocationManager` with `startUpdatingHeading` | Updates within 5 s of phone rotation. Degree value tracks rotation smoothly. |
| GPS lock | `CLLocationManager` with `startUpdatingLocation` | Lock acquired in under 60 s outdoors. Accuracy under 50 m. |
| Accelerometer + gyroscope at 50 Hz | `CMMotionManager` with 0.02 s update interval | Sample counter hit ~500 over a 10-second window. 50 Hz sustained. |
| Camera preview | `AVCaptureSession` with a SwiftUI preview layer | Live preview rendered. Frame rate above 15 FPS in casual observation. |
| Permission prompts | Location, Motion, Camera | All three granted cleanly on first request. No re-prompts needed. |

Conclusion: the demo phone is locked in. iOS 27 introduces no observable regression on CoreLocation, CoreMotion, or AVFoundation. Native iOS is a proven-viable Tier-2 stack on this device.

## Toolchain

| Tool | Version | Validated |
|---|---|---|
| Xcode | 27.0 beta (build 27A5194q) | Installed at `/Applications/Xcode-beta.app`. Active toolchain set via `xcode-select`. |
| iOS SDK | 27.0 | Shipped with Xcode 27 beta. Required for iOS 27 device deployment. |
| Apple Developer signing | Free tier (Personal Team) | 7-day cert. Sufficient for the hackathon window. |
| `xcodegen` | 2.45.4 (via Homebrew) | Generates `.xcodeproj` from `Project.yml`. CLI-driven, no Xcode GUI clicks. |
| `xcrun devicectl` | Ships with Xcode 27 | Install + launch app on the demo phone from CLI after the one-time GUI sign-in. |

End-to-end build + install + launch verified from CLI. The only Xcode GUI step that cannot be skipped is Apple ID sign-in (Settings → Accounts), which is a one-time setup.

## What is NOT yet validated

These are the things we do not yet know about, and are at risk in the hack window:

- **Belt-side servo PWM from ESP32.** Bench-test still required. Includes signal-level confirmation and stall-current behavior under simultaneous actuation.
- **LC2 packet round-trip phone → ESP32.** Includes UDP routing through the venue Wi-Fi or a travel router. M0 milestone.
- **LiDAR scene depth on the demo phone.** `DepthService` is scaffolded but the depth read, the ground-plane behavior at the mount angle, and the directional sampling are not yet confirmed on hardware. M0 and the P-milestones in [`12-perception-and-safety-design.md`](12-perception-and-safety-design.md).
- **Venue magnetometer reliability.** Friday venue gate. Walk the demo room with the phone open. Cannot be validated until Friday.
- **Combined phone load and thermals.** The probe tested each capability in isolation. The full app now adds continuous LiDAR depth and possibly camera Vision on top of heading, GPS, UDP, and UI. Validate them running together at demo cadence, and run a ten-minute thermal soak, before relying on it. This is the biggest open unknown.
- **Coral Edge TPU (optional stretch only).** Not on the base path. Validate only if someone takes the sponsor stretch.

## Why the validation record matters

Hackathon planning often assumes capabilities work and discovers they don't at H+6 when the build is already committed. The capability probe lets the team plan against verified ground truth instead.

If a capability listed above stops working between now and the demo, treat it as a regression and roll the affected toolchain back. Do not assume the OS or Xcode silently changed.

## Probe artifact

The SwiftUI capability probe is a sister repo, kept separate so it can be hacked on without going through this repo's PR flow. It is intentionally throwaway; once the demo phone is locked, the probe's value is mostly historical.

The probe's findings are migrated here. Any future capability question goes through the same probe-then-record pattern.
