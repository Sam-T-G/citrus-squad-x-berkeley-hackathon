import Foundation
import AVFoundation
import Observation

/// The spoken narration of the decided cue: the wearer hears what the belt is doing and what is ahead
/// without touching the screen. The core loop calls `emit(_:)` each tick; this speaks only on a real
/// change or on a hazard that has moved closer, never at the tick rate, so it informs without
/// chattering.
///
/// It is deliberately terse and descriptive: it names what is there, which side, and roughly how close,
/// and it never commands a step or a stop (the wearer and their cane decide that). Proactive hazard
/// narration has to be instant, so every line is built on-device from the cue; the conversational
/// Claude tier is for pulled questions, not for this. While the voice agent has the floor, routine
/// narration holds so the two voices do not collide, but a very close hazard still speaks through.
@MainActor
@Observable
final class AudioCueSink: CueSink {
    /// Turn narration on or off without unregistering it.
    var isEnabled = true

    /// Set by the app each tick. True while the Deepgram agent is listening, thinking, or speaking, so
    /// routine narration defers to it; an urgent (very close) hazard ignores this and speaks anyway.
    var voiceActive = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastEvent: LC2Event = .idle
    private var lastSource: ResolvedCue.Source = .idle
    private var lastProximity: Proximity = .far
    private var lastSpokenAt = Date.distantPast

    /// Coarse closeness bands for speech, derived from the cue's distance-graded intensity. Speech says
    /// "close", never a precise distance: a phone-LiDAR figure is advisory, not an authority the cane
    /// does not already own.
    private enum Proximity: Int {
        case far, near, veryNear
        /// The spoken adjective; empty for the far band, where the side word alone ("ahead") carries it.
        var word: String { self == .veryNear ? "very close" : (self == .near ? "close" : "") }
    }

    func emit(_ cue: ResolvedCue) {
        let proximity = Self.proximity(forIntensity: cue.intensity)
        let changed = cue.event != lastEvent || cue.source != lastSource
        // Re-announce the same hazard only when it has moved into a closer band, so a worsening obstacle
        // is voiced again without repeating an unchanged one.
        let escalated = !changed && cue.source == .hazard && proximity.rawValue > lastProximity.rawValue
        let urgent = proximity == .veryNear && cue.source == .hazard
        defer { lastEvent = cue.event; lastSource = cue.source; lastProximity = proximity }

        guard isEnabled, cue.event != .idle else { return }
        guard changed || escalated else { return }
        // Hold routine narration while the agent is talking, unless this is an urgent hazard.
        guard !voiceActive || urgent else { return }
        // A fresh cue speaks at once; a re-announced escalation waits out the refractory so a hazard
        // creeping closer is not voiced every tick.
        guard changed || Date().timeIntervalSince(lastSpokenAt) >= CitrusSquadConfig.narrationRefractorySeconds else { return }
        guard let phrase = Self.phrase(for: cue, proximity: proximity) else { return }

        lastSpokenAt = Date()
        // Let a new line cut in rather than queue behind a stale one (an urgent hazard must not wait).
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Closeness band from the cue's distance-graded intensity (255 at the danger-near distance, the
    /// floor at the proximity threshold). Mirrors `ResolvedCue.intensity(forDistance:)`.
    private static func proximity(forIntensity intensity: UInt8) -> Proximity {
        if intensity >= 230 { return .veryNear }
        if intensity >= 150 { return .near }
        return .far
    }

    /// Map a cue to a terse spoken line. Describes the situation; never commands a move. Branches on the
    /// event AND the source, because the same wire event means different things from different tiers:
    /// `obstacleNear` from the avoidance layer carries the OPEN side in its mask, not the obstacle's.
    private static func phrase(for cue: ResolvedCue, proximity: Proximity) -> String? {
        // The early-warning tier rides the vision-danger event but is a soft pre-LiDAR advisory.
        if cue.source == .earlyWarning { return "heads up, something ahead" }

        let prox = proximity.word.isEmpty ? "" : proximity.word + " "
        switch cue.event {
        case .forward: return "forward"
        case .turnSlight: return cue.mask.contains(.right) ? "slight right" : "slight left"
        case .turnNow: return cue.mask.contains(.right) ? "turn right" : "turn left"
        case .turnAround:
            // From the avoidance layer this is the boxed-in halt: describe it, do not command. From
            // navigation it is a real route U-turn.
            return cue.source == .hazard ? "obstacle \(prox)ahead, both sides tight" : "turn around"
        case .arrived: return "arrived"
        case .obstacleNear:
            // The LiDAR avoidance steer: the obstacle is AHEAD, and the mask is the open side (more
            // room). State where the room is as fact; the wearer decides how to move.
            if cue.mask.contains(.left) { return "obstacle \(prox)ahead, more room on your left" }
            if cue.mask.contains(.right) { return "obstacle \(prox)ahead, more room on your right" }
            return "obstacle \(prox)ahead"
        case .visionDanger:
            // A person or object the camera recognized, on its own side. Name it when known.
            let what = cue.label?.lowercased() == "person" ? "a person"
                : (cue.label.flatMap { $0.isEmpty ? nil : "a \($0)" } ?? "something")
            let side = cue.mask.contains(.left) ? "on your left"
                : (cue.mask.contains(.right) ? "on your right" : "ahead")
            return "\(what) \(prox)\(side)"
        case .idle: return nil
        }
    }
}
