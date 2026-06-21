import Foundation

/// How soon a detected obstacle becomes a problem.
enum ThreatLevel: Sendable, Equatable {
    case none
    case advisory   // 3–5 m: heads-up
    case warning    // 1.5–3 m: slow down
    case urgent     // < 1.5 m: stop or dodge now
}

/// The recommended physical response, translated into steps for an audio layer.
enum NavigationAction: Sendable, Equatable {
    case clear
    case stepLeft(paces: Int)
    case stepRight(paces: Int)
    case stop
    case slowDown
}

/// A single detected obstacle with its threat level and suggested action.
struct ObstacleThreat: Sendable {
    var label: String
    var distanceMeters: Double
    var horizontalNorm: Double   // 0 = far left, 1 = far right (Vision portrait coordinates)
    var level: ThreatLevel
    var action: NavigationAction
}

/// A detection produced by the CV pipeline before depth fusion.
struct CVDetection: Sendable {
    var label: String
    var confidence: Float
    var horizontalNorm: Double  // Vision portrait coordinate, 0 = left, 1 = right
    var distanceMeters: Double  // -1 if no LiDAR read for this detection
}

/// Pure decision logic: takes raw detections and LiDAR band depths and produces an ObstacleThreat.
/// No sensors, no side effects. Every function here is covered by unit tests.
enum CollisionPredictor {

    static func assess(detections: [CVDetection], bands: BandDepths) -> ObstacleThreat? {
        guard !detections.isEmpty else { return nil }

        // Fuse LiDAR band depth into each detection's distanceMeters.
        let fused = detections.map { fuse(detection: $0, bands: bands) }

        // Only consider things close enough to be a hazard.
        let threats = fused.filter { threatLevel(for: effectiveDistance($0)) != .none }
        guard let nearest = threats.min(by: { effectiveDistance($0) < effectiveDistance($1) }) else { return nil }

        let distance = effectiveDistance(nearest)
        let level = threatLevel(for: distance)
        let action = dodgeAction(for: nearest, bands: bands)
        return ObstacleThreat(label: nearest.label,
                              distanceMeters: distance,
                              horizontalNorm: nearest.horizontalNorm,
                              level: level,
                              action: action)
    }

    // MARK: - Helpers (internal for testability)

    static func threatLevel(for distanceMeters: Double) -> ThreatLevel {
        if distanceMeters <= 0 { return .none }
        if distanceMeters < CitrusSquadConfig.cvUrgentMeters { return .urgent }
        if distanceMeters < CitrusSquadConfig.cvWarningMeters { return .warning }
        if distanceMeters < CitrusSquadConfig.cvAdvisoryMeters { return .advisory }
        return .none
    }

    static func fuse(detection: CVDetection, bands: BandDepths) -> CVDetection {
        guard detection.distanceMeters < 0 else { return detection }
        let depth = bandDepth(for: detection.horizontalNorm, bands: bands)
        var updated = detection
        updated.distanceMeters = depth
        return updated
    }

    static func dodgeAction(for detection: CVDetection, bands: BandDepths) -> NavigationAction {
        let distance = effectiveDistance(detection)
        if distance < CitrusSquadConfig.dangerNearMeters { return .stop }
        if distance >= CitrusSquadConfig.cvWarningMeters { return .slowDown }

        // Object half-width estimate: 0.5 m half-width + 0.5 m clearance margin
        let clearanceNeeded = 1.0
        let paces = max(1, Int(ceil(clearanceNeeded / 0.75)))

        let leftOpen = bands.left < 0 || bands.left > CitrusSquadConfig.proximityThresholdMeters
        let rightOpen = bands.right < 0 || bands.right > CitrusSquadConfig.proximityThresholdMeters

        // Step away from the obstacle's side; prefer the open LiDAR band.
        if detection.horizontalNorm >= 0.5 {
            if leftOpen { return .stepLeft(paces: paces) }
            if rightOpen { return .stepRight(paces: paces) }
        } else {
            if rightOpen { return .stepRight(paces: paces) }
            if leftOpen { return .stepLeft(paces: paces) }
        }
        return .stop
    }

    // MARK: - Private

    private static func effectiveDistance(_ d: CVDetection) -> Double {
        d.distanceMeters > 0 ? d.distanceMeters : CitrusSquadConfig.cvAdvisoryMeters
    }

    static func bandDepth(for horizontalNorm: Double, bands: BandDepths) -> Double {
        if horizontalNorm < 1.0 / 3.0 { return bands.left }
        if horizontalNorm < 2.0 / 3.0 { return bands.center }
        return bands.right
    }
}
