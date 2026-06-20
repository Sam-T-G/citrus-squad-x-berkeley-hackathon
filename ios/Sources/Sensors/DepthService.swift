import Foundation
import ARKit
import Observation
import os

/// Nearest depth in each of three vertical bands of the frame, in meters. -1 means no valid read.
struct BandDepths: Sendable, Equatable {
    var left: Double = -1
    var center: Double = -1
    var right: Double = -1
}

/// LiDAR depth sensing on the iPhone 15 Pro Max via ARKit scene depth. Samples the frame in three
/// vertical bands (left, center, right) so the obstacle cue can fire on the side the obstacle is
/// actually on, per `docs/12-perception-and-safety-design.md`, not just "something ahead."
///
/// ARKit delivers frames on a background queue, so the delegate reduces each frame to three plain
/// `Double`s on that queue and hops only the small value type to the main actor. The non-Sendable
/// `ARFrame` and the depth buffer never cross an isolation boundary.
@MainActor
@Observable
final class DepthService: NSObject {
    private let session = ARSession()
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "depth")

    /// Throttle: process roughly every sixth frame, so a 60 Hz AR feed drives a ~10 Hz read.
    /// ARKit delivers frames on one serial queue, so this counter is only ever touched there.
    /// Kept out of observation so it stays a plain stored property the delegate can mutate.
    @ObservationIgnored nonisolated(unsafe) private var frameTick = 0

    private(set) var isRunning = false
    private(set) var bands = BandDepths()
    private(set) var lastError: String?

    /// Fire the obstacle flag inside this range. Tunable; demo default from `docs/12`.
    var thresholdMeters: Double = CitrusSquadConfig.proximityThresholdMeters

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    /// Closest valid reading across all three bands, for display.
    var nearestMeters: Double {
        [bands.left, bands.center, bands.right].filter { $0 > 0 }.min() ?? -1
    }

    var obstacleAhead: Bool {
        nearestMeters > 0 && nearestMeters <= thresholdMeters
    }

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard isSupported else {
            lastError = "scene depth not supported on this device"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        session.pause()
        isRunning = false
    }
}

extension DepthService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameTick &+= 1
        guard frameTick % 6 == 0, let depth = frame.sceneDepth?.depthMap else { return }
        let sampled = Self.bandedNearest(in: depth)
        Task { @MainActor in self.bands = sampled }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }

    /// Nearest valid depth in each third of the frame. Samples a horizontal strip biased slightly
    /// above center, which favors torso and head-height objects and mostly dodges the floor that a
    /// chest-mounted phone tilts toward. Depth is `kCVPixelFormatType_DepthFloat32`, in meters.
    nonisolated static func bandedNearest(in depthMap: CVPixelBuffer) -> BandDepths {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return BandDepths() }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard width >= 3, height >= 3 else { return BandDepths() }

        let yStart = Int(Double(height) * 0.30)
        let yEnd = Int(Double(height) * 0.55)
        let third = width / 3

        var smallest: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
        for y in yStart..<yEnd {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let value = row[x]
                guard value > 0 else { continue }
                let band = x < third ? 0 : (x < 2 * third ? 1 : 2)
                if value < smallest[band] { smallest[band] = value }
            }
        }

        func meters(_ value: Float) -> Double {
            value == .greatestFiniteMagnitude ? -1 : Double(value)
        }
        return BandDepths(left: meters(smallest[0]), center: meters(smallest[1]), right: meters(smallest[2]))
    }
}

extension DepthService: HazardSource {
    /// The LiDAR reading as a directional hazard, or nil when clear. Fires on the side the obstacle
    /// is on (the closest in-threshold band), escalating to the Far servo when it is very close.
    var currentHazard: Hazard? {
        guard isRunning else { return nil }
        return Self.hazard(left: bands.left, center: bands.center, right: bands.right,
                           threshold: thresholdMeters, near: CitrusSquadConfig.dangerNearMeters)
    }

    /// Pure proximity mapping. Any obstacle within threshold across the three sampled bands warns on
    /// the Back motor; how close it is rides on the intensity, not the motor. Static and pure so it
    /// is unit tested. (`near` is kept for call-site stability and future grading.)
    nonisolated static func hazard(left: Double, center: Double, right: Double,
                                   threshold: Double, near: Double) -> Hazard? {
        let nearest = [left, center, right]
            .filter { $0 > 0 && $0 <= threshold }
            .min()
        guard let distance = nearest else { return nil }
        return Hazard(kind: .obstacle, mask: .back, distanceMeters: distance)
    }
}
