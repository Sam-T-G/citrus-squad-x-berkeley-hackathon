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

    /// Optional callback for the CoreML object detection pipeline. Called on ARKit's serial queue
    /// with every processed frame (same cadence as depth sampling, ~10 Hz). The callback receives
    /// the RGB pixel buffer, the depth pixel buffer (may be nil), and the freshly-sampled band
    /// depths so the CV layer can fuse without a separate main-actor hop.
    /// Stored nonisolated(unsafe): set on the main actor before the session runs, read only on
    /// the ARKit callback queue, so there is no real data race.
    @ObservationIgnored nonisolated(unsafe) var onFrame: ((CVPixelBuffer, CVPixelBuffer?, BandDepths) -> Void)?

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
        onFrame?(frame.capturedImage, depth, sampled)
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

    /// Pure band-to-mask mapping per the `docs/12` table. The closest band within threshold wins;
    /// inside `near` it escalates a side band to its Far servo. Static and pure so it is unit tested.
    nonisolated static func hazard(left: Double, center: Double, right: Double,
                                   threshold: Double, near: Double) -> Hazard? {
        var best: (mask: QuadrantMask, distance: Double)?

        func consider(_ distance: Double, inner: QuadrantMask, outer: QuadrantMask) {
            guard distance > 0, distance <= threshold else { return }
            let mask = distance <= near ? outer : inner
            if best == nil || distance < best!.distance {
                best = (mask, distance)
            }
        }

        consider(left, inner: .left, outer: .farLeft)
        consider(center, inner: .centerMass, outer: .centerMass)
        consider(right, inner: .right, outer: .farRight)

        guard let best else { return nil }
        return Hazard(kind: .obstacle, mask: best.mask, distanceMeters: best.distance)
    }
}
