import Foundation
import AVFoundation
import Observation

/// Josh's plug point for system audio.
///
/// The core loop calls `emit(_:)` with the decided cue every tick. This shell speaks the cue out
/// loud with the system voice as a working starting point, so audio is testable from day one.
/// Josh swaps the body of `emit` for the real audio design (earcons, spatialized tones, ducking,
/// whatever) without touching anything else. It only speaks on a change of cue, so it does not
/// chatter at the 10 Hz tick rate.
@MainActor
@Observable
final class AudioCueSink: CueSink {
    /// Turn audio on or off without unregistering it.
    var isEnabled = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken: LC2Event = .idle

    func emit(_ cue: ResolvedCue) {
        guard isEnabled else { lastSpoken = cue.event; return }
        guard cue.event != lastSpoken else { return }
        lastSpoken = cue.event
        guard cue.event != .idle, let phrase = phrase(for: cue) else { return }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Map a cue to spoken words. Placeholder vocabulary; this is the part Josh designs.
    private func phrase(for cue: ResolvedCue) -> String? {
        switch cue.event {
        case .forward: return "forward"
        case .turnSlight: return cue.mask.contains(.right) ? "slight right" : "slight left"
        case .turnNow: return cue.mask.contains(.right) ? "turn right" : "turn left"
        case .turnAround: return "turn around"
        case .arrived: return "arrived"
        case .obstacleNear: return "obstacle behind"
        case .visionDanger: return "person near"
        case .idle: return nil
        }
    }
}
