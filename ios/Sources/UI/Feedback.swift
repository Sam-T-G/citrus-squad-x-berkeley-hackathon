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

    @MainActor static func cueChanged(to event: LC2Event, source: ResolvedCue.Source = .hazard) {
        // The early-warning tier rides the vision-danger event but is a soft advisory, so it mirrors
        // as a light tap, not the warning buzz a confirmed hazard gets.
        if source == .earlyWarning {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
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

    /// Voice is now listening: the Siri-style begin-record tone plus a haptic, so the wearer knows to
    /// start speaking without looking at the screen.
    @MainActor static func voiceListening() {
        AudioServicesPlaySystemSound(1113)   // begin record
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// The turn ended and the agent is processing: the end-record tone plus a softer haptic.
    @MainActor static func voiceProcessing() {
        AudioServicesPlaySystemSound(1114)   // end record
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
