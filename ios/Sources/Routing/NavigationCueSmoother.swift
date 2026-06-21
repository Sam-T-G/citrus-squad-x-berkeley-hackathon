import Foundation

/// Adds resistance to the navigation turn cue so heading jitter does not make the belt flip between
/// adjacent taps every tick (the "all the servos move very quickly next to each other" problem).
///
/// Two guards, applied in order, both navigation-only. The hazard tiers (a person in the path, the
/// LiDAR obstacle layer) preempt navigation in `AppModel.tick()` and keep their own fast response,
/// so this resistance never slows down a collision reflex. It only steadies the turn-by-turn cue.
///
///  1. **Boundary hysteresis.** The currently held band is widened by a margin before the cue is
///     allowed to leave it, so a bearing that merely dithers across a boundary holds the current
///     cue. The wide rear (turn-around) band gets the larger `docs/04` margin; the rest get the
///     adjacent margin.
///  2. **Dwell.** Once the bearing does cross past the deadband, the new band must persist for a few
///     ticks before it is committed, so a single-frame spike cannot retarget the belt. A genuine
///     turn holds the new band and commits within a few hundred milliseconds.
///
/// Pure value-type state machine: feed it the relative bearing each tick, it returns the cue to fire.
/// Deterministic, so it is unit-tested by replaying a bearing sequence.
struct NavigationCueSmoother {
    private var held: QuadrantMapper.Band?
    private var pending: QuadrantMapper.Band?
    private var pendingTicks = 0

    /// Resolve the cue for this tick's relative bearing, applying hysteresis then dwell.
    mutating func update(relativeBearing: Double,
                         dwellTicks: Int = CitrusSquadConfig.navCueDwellTicks,
                         turnDwellTicks: Int = CitrusSquadConfig.navCueTurnDwellTicks,
                         escalationDegrees: Double = CitrusSquadConfig.navCueEscalationDegrees,
                         adjacentMargin: Double = CitrusSquadConfig.hysteresisAdjacentDegrees,
                         turnAroundMargin: Double = CitrusSquadConfig.hysteresisTurnAroundDegrees) -> Cue {
        let raw = QuadrantMapper.band(forRelativeBearing: relativeBearing)

        // First reading: commit it straight away so the belt is correct from the first tick.
        guard let current = held else {
            held = raw
            pending = nil
            pendingTicks = 0
            return raw.cue
        }

        // Still inside the held band widened by its hysteresis margin: ignore the boundary jitter.
        let margin = current.isTurnAround ? turnAroundMargin : adjacentMargin
        if current.contains(relativeBearing, margin: margin) {
            pending = nil
            pendingTicks = 0
            return current.cue
        }

        // Past the deadband, so this is a real candidate. Count how long it has persisted, then
        // require a dwell sized to how big the correction is: a clear, larger turn commits on the
        // shorter dwell (agency), a small adjacent nudge waits the full one (resistance). The short
        // dwell is still at least two ticks, so a single-frame spike to a far band cannot commit.
        if raw == pending {
            pendingTicks += 1
        } else {
            pending = raw
            pendingTicks = 1
        }
        let swing = Self.swingDegrees(current.center, raw.center)
        let required = swing >= escalationDegrees ? turnDwellTicks : dwellTicks
        if pendingTicks >= max(1, required) {
            held = raw
            pending = nil
            pendingTicks = 0
        }
        return held?.cue ?? raw.cue
    }

    /// Circular distance between two bearings, in [0, 180]. Sizes a band change so the dwell can shrink
    /// for a real turn and stay full for a small nudge.
    private static func swingDegrees(_ a: Double, _ b: Double) -> Double {
        let delta = abs(Bearing.normalize(a) - Bearing.normalize(b))
        return min(delta, 360 - delta)
    }

    /// Forget the held band. Call when a new route loads or driving stops so the next walk starts
    /// from the live bearing instead of inheriting a stale cue.
    mutating func reset() {
        held = nil
        pending = nil
        pendingTicks = 0
    }
}
