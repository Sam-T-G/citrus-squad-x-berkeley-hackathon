import Foundation
import Observation

/// Holds the latest final-approach anchor sightings for the UI and the later, co-designed beacon.
/// Detection runs only while an approach is active (`target` set), so the barcode scan costs nothing on
/// the common path. `targetStreak` counts how many consecutive frames the target marker has decoded,
/// the consistency signal the warmer/colder beacon will read once it is built with blind co-designers.
///
/// This holds data only. It issues no cue, speaks nothing, and never touches the belt safety reflex.
/// The thing that turns a sighting into guidance (the beacon grammar) is deliberately deferred until a
/// blind traveler and an O&M instructor are in the room, per ios/LAST-50-FEET-SCOPING.md Phase 0.
@MainActor
@Observable
final class AnchorStore {
    /// The destination label the wearer is approaching ("room-214"), or nil when no approach is active.
    private(set) var target: String?
    /// Every marker decoded in the latest frame.
    private(set) var sightings: [AnchorSighting] = []
    /// Consecutive frames the target marker has been in view. Resets the moment it drops out, so a lost
    /// marker can never read as steady progress.
    private(set) var targetStreak = 0

    /// True while a final approach is active; the detector scans only then.
    var isApproaching: Bool { target != nil }

    /// The current sighting of the target marker, if it is in view this frame.
    var targetSighting: AnchorSighting? {
        guard let target else { return nil }
        return sightings.first { $0.label == target }
    }

    func startApproach(to label: String) {
        target = label
        sightings = []
        targetStreak = 0
    }

    func stopApproach() {
        target = nil
        sightings = []
        targetStreak = 0
    }

    /// Take the latest frame's sightings. Advances the target's consistency streak, or resets it when
    /// the target is not in view, so absence is always visible rather than coasting on a stale read.
    func update(_ sightings: [AnchorSighting]) {
        self.sightings = sightings
        if target != nil, sightings.contains(where: { $0.label == target }) {
            targetStreak += 1
        } else {
            targetStreak = 0
        }
    }
}
