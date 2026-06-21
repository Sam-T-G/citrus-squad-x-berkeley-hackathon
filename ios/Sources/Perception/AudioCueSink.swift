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
    private var lastSource: ResolvedCue.Source = .idle

    func emit(_ cue: ResolvedCue) {
        guard isEnabled else { lastSpoken = cue.event; lastSource = cue.source; return }
        // Re-speak on a change of cue or its source, so a soft early-warning and a confirmed cue that
        // share the vision-danger wire event are still announced distinctly.
        guard cue.event != lastSpoken || cue.source != lastSource else { return }
        lastSpoken = cue.event
        lastSource = cue.source
        guard cue.event != .idle, let phrase = phrase(for: cue) else { return }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Map a cue to spoken words. Placeholder vocabulary; this is the part Josh designs.
    private func phrase(for cue: ResolvedCue) -> String? {
        // The early-warning tier rides the vision-danger event but is a soft advisory, not a confirmed
        // person, so it speaks its own line. Object-specific phrasing is the Claude advisor's job later.
        if cue.source == .earlyWarning { return "caution, something ahead" }
        switch cue.event {
        case .forward: return "forward"
        case .turnSlight: return cue.mask.contains(.right) ? "slight right" : "slight left"
        case .turnNow: return cue.mask.contains(.right) ? "turn right" : "turn left"
        case .turnAround: return "turn around"
        case .arrived: return "arrived"
        case .obstacleNear: return "obstacle behind"
        case .visionDanger:
            // Say "person" only when the detector saw one; otherwise name the object, or a neutral
            // "obstruction" when the class is unknown.
            if cue.label?.lowercased() == "person" { return "person near" }
            if let label = cue.label, !label.isEmpty { return "\(label) ahead" }
            return "obstruction ahead"
        case .idle: return nil
        }
    }
}
