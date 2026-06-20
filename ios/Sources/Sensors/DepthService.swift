import Foundation
import ARKit
import Observation
import os

/// LiDAR depth sensing on the iPhone 15 Pro Max. Uses ARKit scene depth to report the nearest
/// obstacle distance straight ahead, sampled from the center of the depth map.
///
/// This is the new capability folded into the app. The phone's LiDAR gives raw proximity, which
/// is exactly what the deferred Tier-1 obstacle reflex needed (it was cut only for lack of a ToF
/// sensor, per `docs/01-architecture.md`). For now this service only reports distance and an
/// "obstacle within threshold" flag. Emitting it to the belt over LC2 needs a team-agreed event
/// code, since the pattern vocabulary is capped at four in `docs/03-protocol.md`. See the LiDAR
/// section in `IOS-APP-PLAN.md` for the open decision.
///
/// ARKit delivers frames on a background queue, so the delegate extracts the distance on that
/// queue and hops the plain `Double` to the main actor. The non-Sendable `ARFrame` never crosses.
@MainActor
@Observable
final class DepthService: NSObject {
    private let session = ARSession()
    private let log = Logger(subsystem: "com.samuelgerungan.WAND", category: "depth")

    /// Throttle: process roughly every sixth frame, so a 60 Hz AR feed drives a ~10 Hz read.
    /// ARKit delivers frames on one serial queue, so this counter is only ever touched there.
    /// Kept out of observation so it stays a plain stored property the delegate can mutate.
    @ObservationIgnored nonisolated(unsafe) private var frameTick = 0

    private(set) var isRunning = false
    private(set) var nearestMeters: Double = -1
    private(set) var lastError: String?

    /// Fire the obstacle flag inside this range. Tunable; demo default from `docs/12`.
    var thresholdMeters: Double = WANDConfig.proximityThresholdMeters

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

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
        let meters = Self.nearestMeters(in: depth)
        Task { @MainActor in self.nearestMeters = meters }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }

    /// Smallest valid depth in a small center patch, in meters. Returns -1 if no valid reading.
    /// The depth map is `kCVPixelFormatType_DepthFloat32`, values already in meters.
    nonisolated static func nearestMeters(in depthMap: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return -1 }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let radius = 10
        let cx = width / 2
        let cy = height / 2
        guard cx - radius >= 0, cy - radius >= 0, cx + radius < width, cy + radius < height else {
            return -1
        }

        var smallest = Float.greatestFiniteMagnitude
        for y in (cy - radius)...(cy + radius) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in (cx - radius)...(cx + radius) {
                let value = row[x]
                if value > 0, value < smallest { smallest = value }
            }
        }
        return smallest == .greatestFiniteMagnitude ? -1 : Double(smallest)
    }
}

extension DepthService: HazardSource {
    /// The LiDAR proximity reading as a hazard the arbitration can consume, or nil when clear.
    /// Center mass for now; `docs/12` calls for three-band sampling to make this directional.
    var currentHazard: Hazard? {
        guard isRunning, obstacleAhead else { return nil }
        return Hazard(kind: .obstacle, mask: .centerMass, distanceMeters: nearestMeters)
    }
}
