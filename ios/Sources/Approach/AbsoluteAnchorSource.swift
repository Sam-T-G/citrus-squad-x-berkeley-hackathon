import Foundation
import CoreVideo
import ImageIO
import Vision

/// A source of absolute anchor sightings from one camera frame. The wedge ships a barcode backend now
/// (it works with any coded sticker the team prints, fully on-device, with no asset catalog and no
/// proprietary SDK) behind this protocol, so an `ARImageAnchor` or AprilTag pose backend can slot in
/// later for true metric range without touching the store, the beacon, or the reader. This is the
/// "swappable AbsoluteAnchorSource" seam the scoping review settled on. See
/// ios/LAST-50-FEET-SCOPING.md §2.
/// `Sendable` because `DepthService` holds it as a `let` and calls it from the nonisolated ARSession
/// callback; conformers confine their state to that one queue (the `@unchecked Sendable` discipline).
protocol AbsoluteAnchorSource: AnyObject, Sendable {
    /// Detect and decode anchors in one frame. Synchronous, run on the perception queue like the YOLO
    /// tier; returns the `Sendable` sightings the caller hops to the main actor.
    func detect(in image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [AnchorSighting]
}

/// The shipping backend: Apple's Vision barcode detector on the RGB frame, fully offline and free. It
/// reads the higher-capacity, more aiming-tolerant symbologies (QR, Aztec, DataMatrix) that a
/// blind-aimed chest frame is likelier to catch than a plain frontal QR, and returns each decoded
/// marker's payload, horizontal centroid, and confidence.
///
/// Confined to the one perception queue (`DepthService` calls it from the ARSession callback), so
/// `@unchecked Sendable`, the same discipline as `PersonDetector`: no shared mutable state, one queue.
final class BarcodeAnchorSource: AbsoluteAnchorSource, @unchecked Sendable {
    /// Reused across frames so each scan does not reallocate the request. Safe to hold and mutate
    /// because the source is confined to the one perception queue (the `@unchecked Sendable` discipline).
    /// Aztec and DataMatrix pack more data and decode at wider angles than a plain QR, which matters
    /// for a wearer who cannot aim the camera by sight.
    private let request: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix]
        return request
    }()

    func detect(in image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [AnchorSighting] {
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = (request.results as? [VNBarcodeObservation]) ?? []
        return observations.compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return AnchorSighting(payload: payload,
                                  centroidX: Double(observation.boundingBox.midX),
                                  confidence: Double(observation.confidence),
                                  distanceMeters: nil)
        }
    }
}
