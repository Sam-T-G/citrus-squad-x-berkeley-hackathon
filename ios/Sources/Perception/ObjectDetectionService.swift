import Vision
import CoreML
import ARKit
import Observation
import os

/// Navigation-relevant COCO classes. Matches NAVIGATION_CLASSES in cv/detection.py.
private let navigationClasses: Set<String> = [
    "person", "bicycle", "car", "motorcycle", "bus", "truck",
    "chair", "couch", "dining table", "bed",
    "stop sign", "traffic light", "fire hydrant",
    "bench", "potted plant", "dog", "cat", "backpack", "suitcase", "umbrella",
]

/// On-device YOLOv8n inference fused with ARKit LiDAR depth.
///
/// Hooks into DepthService's ARKit session via the `onFrame` callback, runs a
/// `VNCoreMLRequest` on each captured image, and reports to `VisionHazardSource`
/// using the same `HazardSource` protocol the tick loop already polls.
///
/// The inference + fusion runs on ARKit's serial callback queue (nonisolated). Only
/// the final `Hazard?` result, a `Sendable` value type, crosses to the main actor.
/// The non-Sendable `VNCoreMLModel` and frame counters stay on the callback queue
/// via `nonisolated(unsafe)` storage, matching the pattern in `DepthService`.
///
/// Requires `yolov8n.mlpackage` in the Xcode target:
///   `python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml')"`
/// then drag `yolov8n.mlpackage` into the Xcode project Sources group and add it to the target.
@MainActor
@Observable
final class ObjectDetectionService {
    var isEnabled = true {
        didSet { enabledMirror = isEnabled }
    }

    private(set) var modelLoaded = false
    private(set) var detectionCount = 0
    private(set) var currentThreat: ObstacleThreat?
    /// Objects currently classified as approaching or moving — ready for Claude identification.
    /// Stationary objects are omitted: LiDAR + Sam's param layer handles those.
    private(set) var movingObjects: [TrackedObject] = []
    private(set) var isLogging = false
    private(set) var lastLogURL: URL?
    private(set) var lastError: String?

    // All properties below are accessed only on ARKit's serial callback queue.
    // Same isolation pattern as DepthService.frameTick.
    @ObservationIgnored nonisolated(unsafe) private var detector: VNCoreMLModel?
    @ObservationIgnored nonisolated(unsafe) private var callTick = 0
    @ObservationIgnored nonisolated(unsafe) private var motionFrameIdx = 0
    @ObservationIgnored nonisolated(unsafe) private var settleCount = 0
    @ObservationIgnored nonisolated(unsafe) private var refractoryTicks = 0
    @ObservationIgnored nonisolated(unsafe) private var enabledMirror = true
    @ObservationIgnored nonisolated(unsafe) private weak var hazardSink: VisionHazardSource?
    @ObservationIgnored nonisolated(unsafe) private var tracker = MotionTracker()
    @ObservationIgnored nonisolated(unsafe) private var cvLogger = CVLogger()

    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "cv")

    // MARK: - Lifecycle

    func start(depthService: DepthService, hazard: VisionHazardSource) {
        hazardSink = hazard
        enabledMirror = isEnabled
        depthService.onFrame = { [weak self] image, _, bands in
            self?.processFrame(image: image, bands: bands)
        }
        Task {
            await loadModel()
        }
    }

    func stop(depthService: DepthService) {
        depthService.onFrame = nil
    }

    // MARK: - Session logging

    func startLogging() {
        cvLogger.start()
        isLogging = true
        lastLogURL = nil
    }

    func stopLogging() {
        let url = cvLogger.stop()
        isLogging = false
        lastLogURL = url
    }

    // MARK: - Model loading

    private func loadModel() async {
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage") else {
            lastError = "yolov8n not in bundle — export then add yolov8n.mlpackage to the Xcode target"
            log.warning("CoreML model not found; object detection disabled until model is added")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let ml = try await MLModel.load(contentsOf: url, configuration: config)
            let model = try VNCoreMLModel(for: ml)
            detector = model
            modelLoaded = true
            log.info("YOLOv8n loaded from \(url.lastPathComponent, privacy: .public)")
        } catch {
            lastError = "model load failed: \(error.localizedDescription)"
            log.error("CoreML load error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Frame processing (runs on ARKit callback queue)

    nonisolated func processFrame(image: CVPixelBuffer, bands: BandDepths) {
        guard enabledMirror, let det = detector else { return }

        // Throttle to ~5 Hz (DepthService feeds at ~10 Hz).
        callTick &+= 1
        guard callTick % 2 == 0 else { return }

        let detections = Self.runDetection(model: det, in: image)
        motionFrameIdx &+= 1
        let tracked = tracker.update(detections: detections, frameIndex: motionFrameIdx)
        cvLogger.log(frameIndex: motionFrameIdx, tracked: tracked, bands: bands)

        let hazard = Self.fuseTracked(tracked, bands: bands)
        let settled = advance(hazard: hazard)
        let threat = CollisionPredictor.assess(tracked: tracked, bands: bands)
        let moving = tracked.filter { $0.motionState == .approaching || $0.motionState == .moving }

        let source = hazardSink
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.detectionCount += 1
            self.currentThreat = threat
            self.movingObjects = moving
            if let h = settled {
                source?.report(kind: h.kind, side: h.mask, distanceMeters: h.distanceMeters)
            } else {
                source?.clear()
            }
        }
    }

    // MARK: - Settle and refractory (nonisolated, ARKit queue only)

    /// Require `cvSettleFrames` consecutive detections before reporting.
    /// After clearing a settled hazard, suppress re-firing for `cvRefractoryFrames` ticks.
    nonisolated private func advance(hazard: Hazard?) -> Hazard? {
        if let hazard {
            guard refractoryTicks == 0 else { return nil }
            settleCount += 1
            return settleCount >= CitrusSquadConfig.cvSettleFrames ? hazard : nil
        } else {
            if settleCount >= CitrusSquadConfig.cvSettleFrames {
                refractoryTicks = CitrusSquadConfig.cvRefractoryFrames
            }
            settleCount = 0
            if refractoryTicks > 0 { refractoryTicks -= 1 }
            return nil
        }
    }

    // MARK: - Detection (nonisolated, pure)

    /// Run VNCoreMLRequest on the captured image. Returns navigation-class detections only.
    ///
    /// The YOLOv8n CoreML export must include NMS and Vision metadata so results come back
    /// as `[VNRecognizedObjectObservation]`. If the model outputs a raw feature value instead,
    /// the cast produces an empty array and the service reports nothing (safe failure).
    /// Re-export with `nms=True` if detections are missing: `YOLO('yolov8n.pt').export(format='coreml', nms=True)`.
    nonisolated static func runDetection(model: VNCoreMLModel, in image: CVPixelBuffer) -> [CVDetection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        // .right: ARKit capturedImage is landscape; this rotation corrects it to portrait-up
        // so Vision's bounding box midX == horizontal position in the portrait frame.
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var results: [CVDetection] = []
        for obs in request.results as? [VNRecognizedObjectObservation] ?? [] {
            guard let top = obs.labels.first else { continue }
            guard navigationClasses.contains(top.identifier) else { continue }
            guard top.confidence >= CitrusSquadConfig.cvConfidenceThreshold else { continue }
            results.append(CVDetection(
                label: top.identifier,
                confidence: top.confidence,
                horizontalNorm: Double(obs.boundingBox.midX),
                distanceMeters: -1
            ))
        }
        return results
    }

    /// Fuse tracked objects with LiDAR band depths and pick the most urgent in-path obstacle.
    ///
    /// Motion priority: approaching objects are elevated — they count against advisory range
    /// even if stationary CV detections at the same distance wouldn't. Stationary objects
    /// reported by CV are suppressed unless within warning range (LiDAR already owns those).
    nonisolated static func fuseTracked(_ tracked: [TrackedObject], bands: BandDepths) -> Hazard? {
        var best: (distance: Double, mask: QuadrantMask, kind: Hazard.Kind, priority: Int)?

        for obj in tracked {
            let depth = obj.distanceMeters > 0
                ? obj.distanceMeters
                : CollisionPredictor.bandDepth(for: obj.horizontalNorm, bands: bands)
            guard depth > 0 else { continue }

            let limit: Double
            switch obj.motionState {
            case .approaching: limit = CitrusSquadConfig.cvAdvisoryMeters
            case .moving:      limit = CitrusSquadConfig.cvWarningMeters
            default:           limit = CitrusSquadConfig.cvUrgentMeters
            }
            guard depth <= limit else { continue }

            let mask = quadrantMask(for: obj.horizontalNorm, distance: depth)
            let kind: Hazard.Kind = obj.label == "person" ? .person : .obstacle
            let priority = obj.motionState == .approaching ? 1 : 0

            if let b = best {
                if priority > b.priority || (priority == b.priority && depth < b.distance) {
                    best = (depth, mask, kind, priority)
                }
            } else {
                best = (depth, mask, kind, priority)
            }
        }
        guard let best else { return nil }
        return Hazard(kind: best.kind, mask: best.mask, distanceMeters: best.distance)
    }

    nonisolated private static func quadrantMask(for horizontalNorm: Double, distance: Double) -> QuadrantMask {
        let near = CitrusSquadConfig.dangerNearMeters
        if horizontalNorm < 1.0 / 3.0 { return distance <= near ? .farLeft : .left }
        if horizontalNorm < 2.0 / 3.0 { return .centerMass }
        return distance <= near ? .farRight : .right
    }
}
