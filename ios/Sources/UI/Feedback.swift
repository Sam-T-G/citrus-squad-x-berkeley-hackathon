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

    /// The hold registered and the agent is loading: a light tick so the wearer knows it is coming.
    @MainActor static func voiceActivating() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The agent has loaded and is listening: a bright two-note chime plus the success haptic, a
    /// satisfying "ready" confirmation the wearer hears even on silent (it plays via the media route,
    /// not as a ringer-silenced system sound).
    @MainActor static func voiceReady() {
        ChimePlayer.shared.playReady()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The turn ended and the agent is processing: the end-record tone plus a softer haptic.
    @MainActor static func voiceProcessing() {
        AudioServicesPlaySystemSound(1114)   // end record
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
