import Foundation
import Observation

/// Live, operator-tunable copy of the navigation cue tolerance knobs, seeded from `CitrusSquadConfig`.
/// It lets the belt smoothing be dialed on the phone during demo prep without a rebuild, then left on
/// a value that feels right. `RouteEngine` reads these every tick while driving. The static config
/// values are the defaults and the reset target, so `reset()` is always a known-good baseline to fall
/// back to before a demo run.
///
/// Navigation only. Nothing here touches the person or LiDAR hazard tiers, which preempt navigation
/// and keep their own fast response. See `ios/TOLERANCE-HANDOFF.md` for what each knob does.
@MainActor
@Observable
final class NavTuning {
    /// Dwell for a small adjacent nudge (ticks at 10 Hz). Higher is steadier on wobble, slower to act.
    var dwellTicks: Int = CitrusSquadConfig.navCueDwellTicks
    /// Dwell for a clear, larger turn (ticks). Keep at or above 2 so a single-frame spike cannot commit.
    var turnDwellTicks: Int = CitrusSquadConfig.navCueTurnDwellTicks
    /// Swing (degrees) above which a band change counts as a real turn and takes the shorter dwell.
    var escalationDegrees: Double = CitrusSquadConfig.navCueEscalationDegrees
    /// Deadband margin (degrees) on the normal band boundaries. The main lever for side-to-side chatter.
    var adjacentMarginDegrees: Double = CitrusSquadConfig.hysteresisAdjacentDegrees
    /// Deadband margin (degrees) on the wide rear turn-around band only.
    var turnAroundMarginDegrees: Double = CitrusSquadConfig.hysteresisTurnAroundDegrees

    /// Back to the shipped defaults, the known-good baseline to fall back on mid-demo.
    func reset() {
        dwellTicks = CitrusSquadConfig.navCueDwellTicks
        turnDwellTicks = CitrusSquadConfig.navCueTurnDwellTicks
        escalationDegrees = CitrusSquadConfig.navCueEscalationDegrees
        adjacentMarginDegrees = CitrusSquadConfig.hysteresisAdjacentDegrees
        turnAroundMarginDegrees = CitrusSquadConfig.hysteresisTurnAroundDegrees
    }
}
