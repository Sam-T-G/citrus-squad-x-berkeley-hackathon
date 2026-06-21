import Foundation

/// What the avoidance layer wants the belt to do this tick.
enum AvoidanceDirective: Sendable, Equatable {
    case clear                              // path ahead is open; navigation may proceed
    case steer(QuadrantMask, Double)        // move toward this side (the clearer one); distance in m
    case stop(Double)                       // boxed in or too close: halt and reorient; distance in m
}

/// The LiDAR obstacle-avoidance layer. It sits above navigation and below the camera person tier:
/// when something is in the wearer's forward path it overrides the turn cue and steers them toward
/// the open side, escalating to a stop-and-turn-around when both sides are blocked or something is
/// dangerously close.
///
/// The decision is a pure function of the three depth bands, so it is unit-tested. `AvoidanceFilter`
/// adds the small amount of state that keeps the cue from chattering: an obstacle must persist a few
/// ticks before the cue activates, a clear reading must persist before it releases, and once a side
/// is chosen the layer sticks to it so the wearer is not whipped left-right by band noise.
enum ObstacleAvoidance {
    /// Decide the raw directive from the three bands. `threshold` is the in-path range; `near` is the
    /// danger range that forces a stop. A band of -1 means "no reading" and is treated as open.
    static func decide(left: Double, center: Double, right: Double,
                       threshold: Double, near: Double) -> AvoidanceDirective {
        func isBlocked(_ d: Double) -> Bool { d > 0 && d <= threshold }
        func clearance(_ d: Double) -> Double { d <= 0 ? .greatestFiniteMagnitude : d }

        let blocked = [left, center, right].filter(isBlocked)
        guard let nearest = blocked.min() else { return .clear }   // nothing within range

        let danger = nearest <= near
        let centerBlocked = isBlocked(center)
        // Only take over when the forward path is blocked or something is dangerously close. A lone
        // obstacle off to one side, with the path ahead open, is left to navigation.
        guard centerBlocked || danger else { return .clear }

        let leftBlocked = isBlocked(left)
        let rightBlocked = isBlocked(right)

        // No way through: wall ahead on both sides, or hemmed in at danger range. Halt and reorient.
        if leftBlocked && rightBlocked { return .stop(nearest) }

        // Steer to the open side: away from a blocked side, otherwise toward the roomier one.
        if leftBlocked { return .steer(.right, nearest) }
        if rightBlocked { return .steer(.left, nearest) }
        return clearance(right) >= clearance(left) ? .steer(.right, nearest) : .steer(.left, nearest)
    }
}

/// Debounces the raw avoidance directive over the 10 Hz decide loop. Counts ticks rather than wall
/// time so it stays pure and testable (no clock). A `stop` escalation is immediate; steering settles
/// in over a few ticks and then sticks to its side; a clear must hold before the cue releases.
struct AvoidanceFilter: Sendable {
    private var emitted: AvoidanceDirective = .clear
    private var settleCount = 0
    private var clearCount = 0

    var settleTicks: Int = CitrusSquadConfig.obstacleSettleTicks
    var holdTicks: Int = CitrusSquadConfig.obstacleHoldTicks

    mutating func update(_ raw: AvoidanceDirective) -> AvoidanceDirective {
        switch raw {
        case .stop:
            // Danger trumps everything and fires at once.
            emitted = raw
            settleCount = settleTicks
            clearCount = 0
        case .clear:
            settleCount = 0
            clearCount += 1
            if clearCount >= holdTicks { emitted = .clear }
        case .steer:
            clearCount = 0
            settleCount += 1
            switch emitted {
            case .clear, .stop:
                if settleCount >= settleTicks { emitted = raw }   // activate after it settles
            case .steer:
                break                                             // sticky: keep the chosen side
            }
        }
        return emitted
    }
}
