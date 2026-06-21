import Foundation

/// The demo-console surface for the early-warning layer. `BearingTracker` produces `InterferenceFlag`
/// values off the perception path; this holds the latest set so the camera panel can show them. It is
/// diagnostics only in this step: nothing here touches the belt or the cue arbitration. When step 3
/// wires the soft cue, `AppModel` reads `active` here and fires the gentle tap, still below the
/// LiDAR and collision tiers.
///
/// Same shape as `DetectionStore`: a main-actor `@Observable` the UI reads, fed from the frame loop.
@MainActor
@Observable
final class InterferenceStore {
    /// Every flag the tracker raised on the latest processed frame.
    private(set) var flags: [InterferenceFlag] = []
    /// Running count of frames that raised at least one flag, for the console readout.
    private(set) var flaggedFrameCount = 0
    var isEnabled = true

    /// The most urgent flag this frame: soonest contact wins, confidence breaks ties. Nil when clear.
    var active: InterferenceFlag? {
        flags.min { lhs, rhs in
            let l = lhs.timeToContactSeconds ?? .greatestFiniteMagnitude
            let r = rhs.timeToContactSeconds ?? .greatestFiniteMagnitude
            if l != r { return l < r }
            return rank(lhs.confidence) > rank(rhs.confidence)
        }
    }

    func update(_ flags: [InterferenceFlag]) {
        self.flags = isEnabled ? flags : []
        if isEnabled, !flags.isEmpty { flaggedFrameCount += 1 }
    }

    func clear() {
        flags = []
    }

    private func rank(_ c: InterferenceConfidence) -> Int {
        switch c {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}
