import Foundation

/// Session recorder for the CV + motion pipeline.
///
/// Call `start()` before a test walk, `stop()` when done. Rows are buffered in memory
/// and flushed to a CSV in Documents only on stop — no disk I/O on the ARKit callback
/// queue. Open the file in any spreadsheet to inspect raw YOLO detections, computed
/// approach rates, and motion states frame-by-frame. Tune `MotionParameters` thresholds
/// against the numbers before committing to a value.
///
/// Not actor-isolated. Store as `nonisolated(unsafe)` in `ObjectDetectionService` and
/// call only from the ARKit callback queue, same pattern as `MotionTracker`.
final class CVLogger {

    static let csvHeader = "timestamp_ms,frame,label,confidence,h_norm,dist_m,approach_mps,lateral_nps,motion_state,frames_tracked,band_left,band_center,band_right"

    private var buffer: [String] = []
    private(set) var isLogging = false
    private var sessionStart: UInt64 = 0

    // MARK: - Control (call on ARKit queue)

    func start() {
        buffer = [Self.csvHeader]
        sessionStart = UInt64(Date().timeIntervalSince1970 * 1000)
        isLogging = true
    }

    /// Flush buffer to a timestamped CSV in Documents. Returns the file URL or nil on failure.
    func stop() -> URL? {
        isLogging = false
        guard buffer.count > 1 else { return nil }

        let name = "cv_log_\(sessionStart).csv"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent(name)

        let content = buffer.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        buffer = []
        return url
    }

    // MARK: - Logging (call on ARKit queue)

    func log(frameIndex: Int, tracked: [TrackedObject], bands: BandDepths) {
        guard isLogging else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000) - sessionStart

        if tracked.isEmpty {
            // Log an empty-frame sentinel so gaps in detection are visible.
            buffer.append("\(ts),\(frameIndex),,,,,,,none,0,\(fmt(bands.left)),\(fmt(bands.center)),\(fmt(bands.right))")
            return
        }

        for obj in tracked {
            let row = [
                "\(ts)",
                "\(frameIndex)",
                obj.label,
                String(format: "%.3f", obj.confidence),
                String(format: "%.4f", obj.horizontalNorm),
                String(format: "%.3f", obj.distanceMeters),
                String(format: "%.4f", obj.approachRateMetersPerSecond),
                String(format: "%.4f", obj.lateralRateNormPerSecond),
                "\(obj.motionState)",
                "\(obj.framesTracked)",
                fmt(bands.left),
                fmt(bands.center),
                fmt(bands.right),
            ].joined(separator: ",")
            buffer.append(row)
        }
    }

    // MARK: - Helpers

    private func fmt(_ value: Double) -> String {
        value < 0 ? "-1" : String(format: "%.3f", value)
    }
}
