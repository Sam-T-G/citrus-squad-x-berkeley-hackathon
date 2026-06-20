import UIKit
import AudioToolbox

/// Operator and wearer feedback on the phone.
///
/// Calibration plays a chime plus a success haptic so the wearer knows it took without looking at
/// the screen, the default confirmation in `docs/04-phone-side.md`. Cue changes pulse a haptic that
/// mirrors what the belt is doing, which also makes the demo legible from the phone alone when no
/// belt is attached.
enum Feedback {
    @MainActor static func calibrationConfirmed() {
        AudioServicesPlaySystemSound(1057)   // short "Tink", reliable in a noisy room
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor static func cueChanged(to event: LC2Event) {
        switch event {
        case .arrived:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .obstacleNear, .visionDanger:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .forward:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .turnSlight, .turnNow, .turnAround:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .idle:
            break
        }
    }
}
