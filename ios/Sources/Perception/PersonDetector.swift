import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Vision
import CoreML
import os

/// One fused detection of an in-path object, the Swift mirror of `DepthFusedDetection` in
/// `cv/detection.py`. `label` is the COCO class (`person`, `bicycle`, `bench`, ...); the gate and
/// fusion math ignore it, but the overlay, diagnostics, and spoken tier read it.
struct PersonDetection: Sendable, Equatable {
    /// COCO class name from `CitrusSquadConfig.visionNavigationClasses`.
    var label: String
    var confidence: Float
    /// Box in the upright image, normalized 0...1, top-left origin.
    var boxNormalized: CGRect
    var depthMedianMeters: Double?
    var depthMinMeters: Double?
    /// 0 at the far left of the upright frame, 1 at the far right.
    var horizontalNorm: Double
}

/// State for the settle / hysteresis / refractory discipline in `docs/12` §6. Advanced once per
/// processed frame. The transitions live in `PersonDetector.decide`, a pure function, so the timing
/// rules are unit tested without a camera.
struct PersonGate: Equatable, Sendable {
    /// Consecutive frames a person has been seen inside the fire range.
    var consecutive = 0
    /// Whether the cue is currently asserted.
    var firing = false
    /// Timestamp of the last fire-or-clear transition, in seconds.
    var lastChange = 0.0
}

/// What the gate decided for a frame.
enum PersonAction: Equatable, Sendable {
    case report(side: QuadrantMask, distanceMeters: Double)
    case clear
    /// No state change. Leave the current cue exactly as it is.
    case hold
}

/// Timing knobs for `decide`, sourced from `CitrusSquadConfig`.
struct GateConfig: Sendable {
    var threshold: Double
    var hysteresis: Double
    var settleFrames: Int
    var refractory: Double
}

/// Everything `process` needs for one frame, sourced from `CitrusSquadConfig`.
struct ProcessConfig: Sendable {
    var confidence: Float
    var cropRatio: Double
    var gate: GateConfig

    static let demo = ProcessConfig(
        confidence: CitrusSquadConfig.visionConfidenceThreshold,
        cropRatio: CitrusSquadConfig.depthCropRatio,
        gate: GateConfig(threshold: CitrusSquadConfig.proximityThresholdMeters,
                         hysteresis: CitrusSquadConfig.visionHysteresisMeters,
                         settleFrames: CitrusSquadConfig.visionSettleFrames,
                         refractory: CitrusSquadConfig.visionRefractorySeconds))
}

/// Result of processing one frame: what to do with the cue, the boxes for the demo overlay, and the
/// full depth-fused scene for the Claude tier.
struct PersonFrameResult: Sendable {
    var action: PersonAction
    /// Normalized top-left boxes for `DetectionStore` to draw over the preview.
    var overlay: [Detection]
    /// The nearest person this frame, for the diagnostics console. Nil when none.
    var best: PersonDetection?
    /// Every detection this frame with its LiDAR-fused depth and horizontal position. This is the rich
    /// CV-plus-LiDAR scene the `PerceptionSnapshot` hands to Claude so it can describe the whole frame
    /// (what is in each band and how close), not just the single nearest hazard.
    var scene: [PersonDetection]
}

/// Runs YOLOv8n (via CoreML + Vision) on the ARKit RGB frame, fuses the box with the LiDAR depth
/// map using the same math Cole proved in Python, and turns the nearest in-path object (any class in
/// `CitrusSquadConfig.visionNavigationClasses`) into a gated cue.
///
/// Concurrency: all state lives on one serial queue (the ARKit perception queue in `DepthService`).
/// `process` is called only from there, so the class is `@unchecked Sendable`: there is no real
/// shared mutation, the model and gate are touched on exactly one queue. Only the `Sendable`
/// `PersonFrameResult` ever leaves, hopped to the main actor by the caller.
final class PersonDetector: @unchecked Sendable {
    private var model: VNCoreMLModel?
    private var modelLoadFailed = false
    private var gate = PersonGate()
    private var lastInference = 0.0
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "vision")

    /// True once the model is loaded and detection can run. The UI reads this to show the tier state.
    private(set) var isModelReady = false

    // MARK: - Frame processing

    /// Process one ARKit frame. Returns nil when the throttle skips this frame, so the caller leaves
    /// the cue untouched. Runs synchronously on the perception queue.
    func process(image: CVPixelBuffer, depth: CVPixelBuffer?,
                 orientation: CGImagePropertyOrientation,
                 now: Double, throttleInterval: Double,
                 config: ProcessConfig) -> PersonFrameResult? {
        guard now - lastInference >= throttleInterval else { return nil }
        lastInference = now

        loadModelIfNeeded()
        guard let model else {
            // No model bundled yet (Cole's CoreML export is the P0 dependency). Never fire; keep the
            // gate's clear path alive so a stale cue cannot stick.
            return advance(distance: -1, side: .front, now: now, config: config, overlay: [], best: nil, scene: [])
        }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("vision request failed: \(error.localizedDescription, privacy: .public)")
            return advance(distance: -1, side: .front, now: now, config: config, overlay: [], best: nil, scene: [])
        }

        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []

        var overlay: [Detection] = []
        var people: [PersonDetection] = []
        for obs in observations {
            guard let label = navigationLabel(obs, minConfidence: config.confidence) else { continue }
            let bb = obs.boundingBox                      // normalized, bottom-left origin, upright frame
            let topLeft = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
            overlay.append(Detection(label: label, confidence: Double(obs.confidence), box: topLeft))

            var median: Double?
            var minDepth: Double?
            if let depth {
                let nativeNorm = Self.toNativeNormalized(topLeft, orientation: orientation)
                (median, minDepth) = Self.sampleDepth(depth, nativeNormalizedBox: nativeNorm,
                                                       cropRatio: config.cropRatio)
            }
            people.append(PersonDetection(label: label, confidence: obs.confidence, boxNormalized: topLeft,
                                          depthMedianMeters: median, depthMinMeters: minDepth,
                                          horizontalNorm: Double(topLeft.midX)))
        }

        // The nearest object with a valid depth drives the cue; ties fall back to confidence.
        let best = people
            .filter { $0.depthMinMeters != nil }
            .min { ($0.depthMinMeters ?? .greatestFiniteMagnitude) < ($1.depthMinMeters ?? .greatestFiniteMagnitude) }
            ?? people.max { $0.confidence < $1.confidence }

        let distance = best?.depthMinMeters ?? -1
        let side = best.map { PersonFusion.quadrant(horizontalNorm: $0.horizontalNorm) } ?? .front
        return advance(distance: distance, side: side, now: now, config: config,
                       overlay: overlay, best: best, scene: people)
    }

    private func advance(distance: Double, side: QuadrantMask, now: Double,
                         config: ProcessConfig, overlay: [Detection],
                         best: PersonDetection?, scene: [PersonDetection]) -> PersonFrameResult {
        let (action, next) = Self.decide(distance: distance, side: side, gate: gate, now: now, cfg: config.gate)
        gate = next
        return PersonFrameResult(action: action, overlay: overlay, best: best, scene: scene)
    }

    /// The navigation-class label for an observation, or nil to ignore it. Replaces the person-only
    /// filter: any class in `CitrusSquadConfig.visionNavigationClasses` is an in-path hazard
    /// candidate. Uses the observation's objectness confidence, the same floor the person filter
    /// used, so detection sensitivity is unchanged; only the accepted label set is wider.
    private func navigationLabel(_ obs: VNRecognizedObjectObservation, minConfidence: Float) -> String? {
        guard obs.confidence >= minConfidence, let top = obs.labels.first else { return nil }
        return CitrusSquadConfig.visionNavigationClasses.contains(top.identifier) ? top.identifier : nil
    }

    // MARK: - Model

    private func loadModelIfNeeded() {
        guard model == nil, !modelLoadFailed else { return }
        // A compiled `.mlpackage` lands in the bundle as `.mlmodelc`; accept either so the build does
        // not depend on which form Cole ships.
        let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
        guard let url else {
            modelLoadFailed = true
            log.error("yolov8n model not bundled; person tier disabled until the CoreML export lands")
            return
        }
        do {
            let mlModel = try MLModel(contentsOf: url)
            model = try VNCoreMLModel(for: mlModel)
            isModelReady = true
            log.info("yolov8n loaded; person tier live")
        } catch {
            modelLoadFailed = true
            log.error("failed to load yolov8n: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pure transitions (unit tested)

    /// The settle / hysteresis / refractory state machine from `docs/12` §6. `distance` is the fused
    /// closest depth in meters, or <= 0 when there is no person or no valid depth.
    static func decide(distance: Double, side: QuadrantMask, gate: PersonGate,
                       now: Double, cfg: GateConfig) -> (PersonAction, PersonGate) {
        var g = gate
        let inFireRange = distance > 0 && distance <= cfg.threshold
        let inHoldRange = distance > 0 && distance <= cfg.threshold + cfg.hysteresis

        if g.firing {
            // Stay firing across the hysteresis band; track side and distance for live intensity.
            if inHoldRange {
                return (.report(side: side, distanceMeters: distance), g)
            }
            // Person left the band. Hold the cue until the refractory floor passes, then clear once.
            if now - g.lastChange >= cfg.refractory {
                g.firing = false
                g.consecutive = 0
                g.lastChange = now
                return (.clear, g)
            }
            return (.hold, g)
        }

        // Not firing: a person must persist in the fire range before the cue asserts.
        if inFireRange {
            g.consecutive += 1
            if g.consecutive >= cfg.settleFrames && now - g.lastChange >= cfg.refractory {
                g.firing = true
                g.lastChange = now
                return (.report(side: side, distanceMeters: distance), g)
            }
            return (.hold, g)
        }

        g.consecutive = 0
        return (.hold, g)
    }

    // MARK: - Orientation and depth sampling

    /// Map an upright, top-left normalized box to the camera's native (stored) normalized space, so
    /// it lines up with the depth buffer, which is delivered in native orientation alongside the RGB
    /// frame. `.up` is identity; `.right` is the portrait rear-camera case.
    ///
    /// ON-DEVICE CALIBRATION: the `.right` rotation is the one runtime unknown in this whole port.
    /// Verify once by holding a target hard left and confirming a left-side tap. If the side is
    /// mirrored or swapped, this function is where to fix it. Everything numeric downstream is tested.
    static func toNativeNormalized(_ upright: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .right:
            // Upright was produced by rotating the native frame 90° clockwise for display, so map
            // back the other way: native_x = upright_y, native_y = 1 - upright_x.
            let x = upright.minY
            let y = 1 - upright.maxX
            return CGRect(x: x, y: y, width: upright.height, height: upright.width)
        case .left:
            let x = 1 - upright.maxY
            let y = upright.minX
            return CGRect(x: x, y: y, width: upright.height, height: upright.width)
        case .down:
            return CGRect(x: 1 - upright.maxX, y: 1 - upright.maxY, width: upright.width, height: upright.height)
        default:
            return upright
        }
    }

    /// Median and closest valid depth inside the box, reading the LiDAR buffer directly. Mirrors
    /// `PersonFusion.sample` (which is unit tested) but over a `CVPixelBuffer` to avoid a copy. The
    /// box is native-normalized, scaled here to the depth buffer's pixel grid.
    static func sampleDepth(_ depth: CVPixelBuffer, nativeNormalizedBox box: CGRect,
                            cropRatio: Double) -> (median: Double?, min: Double?) {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return (nil, nil) }
        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        let pxBox = CGRect(x: box.minX * CGFloat(dw), y: box.minY * CGFloat(dh),
                           width: box.width * CGFloat(dw), height: box.height * CGFloat(dh))
        let window = PersonFusion.depthWindow(boxPx: pxBox, rgbSize: CGSize(width: dw, height: dh),
                                              depthSize: CGSize(width: dw, height: dh), cropRatio: cropRatio)
        guard !window.isEmpty else { return (nil, nil) }

        var valid: [Float] = []
        for y in window.y1..<window.y2 where y >= 0 && y < dh {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in window.x1..<window.x2 where x >= 0 && x < dw {
                let value = row[x]
                if value.isFinite && value > 0 { valid.append(value) }
            }
        }
        return PersonFusion.medianMin(valid)
    }
}
