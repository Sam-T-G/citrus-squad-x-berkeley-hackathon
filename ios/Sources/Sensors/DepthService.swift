import Foundation
import ARKit
import CoreImage
import ImageIO
import Observation
import os

/// CGImage is immutable once created, so it is safe to carry across the hop from the perception
/// queue to the main actor.
private struct SendableImage: @unchecked Sendable { let image: CGImage }

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

    /// One serial queue carries every ARFrame, so the depth band scan and the heavier vision
    /// inference both run off the main thread. The delegate's `nonisolated(unsafe)` state is touched
    /// only here, which is what makes that annotation sound.
    private let perceptionQueue = DispatchQueue(label: "com.citrussquad.perception", qos: .userInitiated)

    /// Throttle: process roughly every sixth frame, so a 60 Hz AR feed drives a ~10 Hz read.
    /// ARKit delivers frames on one serial queue, so this counter is only ever touched there.
    /// Kept out of observation so it stays a plain stored property the delegate can mutate.
    @ObservationIgnored nonisolated(unsafe) private var frameTick = 0

    /// Person-in-path detector. The same ARFrame carries the RGB image and the depth map, so one
    /// ARSession feeds both tiers; there is no second camera. It is `Sendable` and its own state is
    /// confined to the perception queue, so a plain `let` reads cleanly from the delegate. See
    /// `Perception/PersonDetector.swift` and `CV-PORT-PLAN.md`.
    private let personDetector = PersonDetector()

    /// Gate for the camera tier, toggled off the main actor by the thermal degrade ladder.
    @ObservationIgnored nonisolated(unsafe) var visionEnabled = true

    /// Where a resolved person cue and the overlay boxes go. Set once by `AppModel.attachVision`.
    private weak var visionSink: VisionHazardSource?
    private weak var detectionStore: DetectionStore?

    /// Early-warning layer (diagnostics only in this step). The tracker watches the per-frame boxes
    /// for an object holding the wearer's heading and growing, and flags it before LiDAR has a return.
    /// It runs on the main actor inside `applyVision`, where the boxes and the yaw rate are both in
    /// reach, so it stays off the heavy perception queue. See `Perception/BearingTracker.swift`.
    private let bearingTracker = BearingTracker()
    private var bearingFrameIndex = 0
    private weak var interferenceStore: InterferenceStore?

    /// Wearer yaw rate in rad/s, refreshed each decide tick by `AppModel` from `MotionService`. Feeds
    /// the tracker's self-rotation gate so a head turn does not read as a centered obstacle.
    var latestYawRate: Double = 0

    /// Rear camera in portrait. The one runtime unknown; see `PersonDetector.toNativeNormalized`.
    nonisolated private static let cameraOrientation: CGImagePropertyOrientation = .right
    nonisolated private static let visionThrottle = 1.0 / CitrusSquadConfig.visionMaxHz

    private(set) var isRunning = false
    private(set) var bands = BandDepths()
    private(set) var lastError: String?

    /// A downscaled RGB frame for the demo preview, taken from the same ARFrame the depth and the
    /// detector use. Nil when depth is not running. This is what lets the camera panel show the live
    /// feed while LiDAR and the person tier run, with no second capture session to contend over the
    /// rear camera.
    private(set) var previewImage: CGImage?

    /// The latest higher-resolution upright frame, kept for the pull-based Claude vision read ("what's
    /// around me", "read that sign"). Refreshed at ~2 Hz from the same ARSession, so there is no second
    /// capture session contending for the rear camera. Nil when depth is not running. The read encodes
    /// this to JPEG on demand, so most frames cost only the cache, never an encode. See `ClaudeClient`
    /// and `AI-USAGE-AUDIT-AND-EXPANSION.md`.
    private(set) var latestVisionFrame: CGImage?

    /// CIContext is documented thread-safe for rendering, so the perception queue uses it directly.
    nonisolated(unsafe) private let ciContext = CIContext(options: nil)

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
        session.delegateQueue = perceptionQueue
    }

    /// Wire the person tier to its sink, the demo overlay, and the early-warning surface. Called once
    /// by `AppModel`.
    func attachVision(sink: VisionHazardSource, store: DetectionStore, interference: InterferenceStore) {
        visionSink = sink
        detectionStore = store
        interferenceStore = interference
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
        previewImage = nil
        latestVisionFrame = nil
    }

    /// Encode the latest cached frame to JPEG for a Claude vision call. Main-actor and on demand, so
    /// the encode happens only when the wearer asks, never on the perception queue. Nil when no frame
    /// is cached (camera off). 1280 px long edge keeps small text legible while bounding tokens.
    func grabFrameJPEG(quality: Double = 0.7) -> Data? {
        guard let image = latestVisionFrame else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension DepthService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameTick &+= 1
        guard frameTick % 6 == 0, let depth = frame.sceneDepth?.depthMap else { return }
        let sampled = Self.bandedNearest(in: depth)
        Task { @MainActor in self.bands = sampled }

        // Publish a downscaled preview from the same frame so the demo shows the camera, LiDAR, and
        // the detector from one session. Throttled below the band rate; it is cosmetic, so it is the
        // first thing to shed under load.
        if frameTick % 12 == 0, let cg = Self.previewImage(from: frame.capturedImage, context: ciContext) {
            let wrapped = SendableImage(image: cg)
            Task { @MainActor in self.previewImage = wrapped.image }
        }

        // Keep a higher-resolution frame for the pull-based Claude vision read, slower than the preview
        // because nothing consumes it until the wearer asks. Same frame, no second camera session.
        if frameTick % 30 == 0, let cg = Self.visionImage(from: frame.capturedImage, context: ciContext) {
            let wrapped = SendableImage(image: cg)
            Task { @MainActor in self.latestVisionFrame = wrapped.image }
        }

        // Person tier off the same frame: RGB for YOLO, this depth map for fusion. process() throttles
        // itself to the camera rate, so most frames return nil here and the cue is left untouched.
        guard visionEnabled else { return }
        let result = personDetector.process(
            image: frame.capturedImage, depth: depth, orientation: Self.cameraOrientation,
            now: frame.timestamp, throttleInterval: Self.visionThrottle, config: .demo)
        if let result {
            Task { @MainActor in self.applyVision(result) }
        }
    }

    /// Push the gated person cue and the overlay boxes to the main actor. `.hold` leaves the cue
    /// exactly as the last tick set it.
    @MainActor private func applyVision(_ result: PersonFrameResult) {
        switch result.action {
        case .report(let side, let distance):
            // The wire event stays vision-danger for any close navigation-class object, but carry the
            // detected label so the demo and voice name what is ahead instead of always saying person.
            visionSink?.report(kind: .person, side: side, distanceMeters: distance,
                               label: result.best?.label)
        case .clear:
            visionSink?.clear()
        case .hold:
            break
        }
        detectionStore?.update(result.overlay)

        // Early-warning pass: the same boxes, watched across frames for constant bearing plus looming.
        // Diagnostics only here; the flags surface in the demo console and touch no cue. boxHeight is
        // the looming signal, horizontalNorm the bearing.
        bearingFrameIndex += 1
        let observations = result.overlay.map {
            BoxObservation(label: $0.label, confidence: $0.confidence,
                           horizontalNorm: Double($0.box.midX), boxHeight: Double($0.box.height))
        }
        let flags = bearingTracker.update(observations: observations,
                                          yawRateRadPerSecond: latestYawRate,
                                          frameIndex: bearingFrameIndex)
        interferenceStore?.update(flags)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }

    /// Nearest valid depth in the scene's left, center, and right thirds. The buffer is the camera's
    /// native landscape orientation, so in portrait the scene's left-right runs along the rows: this
    /// splits the rows into three bands and scans an upper-middle column strip, favoring torso height
    /// and dodging the floor. Depth is `kCVPixelFormatType_DepthFloat32`, in meters.
    nonisolated static func bandedNearest(in depthMap: CVPixelBuffer) -> BandDepths {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return BandDepths() }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard width >= 3, height >= 3 else { return BandDepths() }

        // The depth buffer is the camera's native landscape orientation. In portrait (.right) the
        // scene's left-right runs along the buffer's HEIGHT (rows) and its up-down along the WIDTH
        // (columns) — so to read left/center/right of what the wearer faces, split the ROWS into three
        // bands and scan an upper-middle COLUMN strip to favor torso/obstacle height and dodge the
        // floor. For .right, row 0 is the scene's right edge, so band 0 is right and band 2 is left.
        let colStart = Int(Double(width) * 0.30)
        let colEnd = Int(Double(width) * 0.55)
        let bandRows = height / 3

        var smallest: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
        for y in 0..<height {
            let band = y < bandRows ? 0 : (y < 2 * bandRows ? 1 : 2)
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in colStart..<colEnd {
                let value = row[x]
                guard value > 0 else { continue }
                if value < smallest[band] { smallest[band] = value }
            }
        }

        func meters(_ value: Float) -> Double {
            value == .greatestFiniteMagnitude ? -1 : Double(value)
        }
        // band 0 = scene right, band 2 = scene left. If a live test shows them mirrored, swap these.
        return BandDepths(left: meters(smallest[2]), center: meters(smallest[1]), right: meters(smallest[0]))
    }

    /// A downscaled, upright CGImage from the AR frame's RGB buffer for the demo preview. Oriented
    /// the same way as the detector so the overlay boxes line up. Nil if the buffer is empty.
    nonisolated static func previewImage(from pixelBuffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(cameraOrientation)
        guard oriented.extent.width > 0 else { return nil }
        let scale = 480.0 / oriented.extent.width
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// An upright, higher-resolution CGImage for the Claude vision read. Same orientation as the
    /// preview and the detector. Scaled so the long edge is at most 1280 px: enough to read a street
    /// sign or bus number, small enough to keep the request light. Nil if the buffer is empty.
    nonisolated static func visionImage(from pixelBuffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(cameraOrientation)
        let longEdge = max(oriented.extent.width, oriented.extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1.0, 1280.0 / longEdge)
        let scaled = scale < 1 ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : oriented
        return context.createCGImage(scaled, from: scaled.extent)
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
