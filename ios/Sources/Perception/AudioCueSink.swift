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

    /// Set by the app each tick. True while the Deepgram agent has a turn open (listening, thinking, or
    /// speaking), so routine narration defers to it; an imminent hazard speaks through.
    var voiceActive = false
    /// Set by the app each tick. True only while the agent's text-to-speech is actually playing. The
    /// imminent speak-through holds for this narrow window so two synthetic voices never overlap.
    var agentSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    // What was last actually SPOKEN, advanced only when a line is spoken (never per tick). Tracking the
    // spoken state, not the per-tick state, is what stops a suppressed cue from being silently absorbed:
    // a hazard that could not speak this tick stays "changed"/"escalated" until it actually gets voiced.
    private var spokenEvent: LC2Event = .idle
    private var spokenSource: ResolvedCue.Source = .idle
    private var spokenProximity: Proximity = .far
    private var spokenImminent = false
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
        let isHazard = cue.source == .hazard
        // Imminent: close enough that the wearer needs to keep hearing about it. Deliberately more
        // liberal than the "very close" speech band, so a hazard within range is voiced repeatedly.
        let imminent = isHazard && cue.intensity >= CitrusSquadConfig.narrationImminentIntensity
        // Measured against what was last SPOKEN, so a cue that could not speak yet is not lost.
        let changed = cue.event != spokenEvent || cue.source != spokenSource
        let escalated = !changed && isHazard && proximity.rawValue > spokenProximity.rawValue

        guard isEnabled, cue.event != .idle else { return }

        // Decide whether this tick speaks. A new cue speaks, but no sooner than a small gap after the
        // last line so flapping events cannot machine-gun. An imminent hazard re-announces on a short
        // floor so it never goes silent while close. A non-imminent worsening re-announces on the
        // slower refractory. Everything else stays quiet.
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastSpokenAt)
        let speak: Bool
        if changed {
            speak = sinceLast >= CitrusSquadConfig.narrationMinGapSeconds
        } else if imminent {
            speak = sinceLast >= CitrusSquadConfig.narrationImminentRepeatSeconds
        } else if escalated {
            speak = sinceLast >= CitrusSquadConfig.narrationRefractorySeconds
        } else {
            speak = false
        }
        guard speak else { return }
        // Routine narration defers to a voice turn; an imminent hazard speaks through, but never while
        // the agent's TTS is actually playing, so two synthetic voices never overlap.
        guard !voiceActive || (imminent && !agentSpeaking) else { return }

        // A new imminent hazard may cut in over a routine line (the close obstacle matters more); never
        // cut in over another imminent line or for a routine cue, so nothing machine-guns or chops a
        // hazard line. Anything that does not cut in waits for the current line to finish, and stays
        // pending because the spoken state has not advanced.
        if synthesizer.isSpeaking {
            guard changed, imminent, !spokenImminent else { return }
            synthesizer.stopSpeaking(at: .word)
        }
        guard let phrase = Self.phrase(for: cue, proximity: proximity) else { return }

        lastSpokenAt = now
        spokenEvent = cue.event
        spokenSource = cue.source
        spokenProximity = proximity
        spokenImminent = imminent
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
