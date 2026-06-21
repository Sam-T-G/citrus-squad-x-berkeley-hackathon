import Foundation

/// Tracks YOLO detections across frames, computes approach velocity and lateral motion,
/// and classifies each as stationary / moving / approaching / receding.
///
/// Not actor-isolated. Store as `nonisolated(unsafe)` in `ObjectDetectionService` and
/// call only from the ARKit callback queue (same serial queue pattern as `DepthService.frameTick`).
/// Matches the Mira project's parameter-based motion library: all thresholds in `MotionParameters`,
/// no AI involved. Claude fires separately only when `motionState == .approaching`.
final class MotionTracker {

    // MARK: - Private state

    private struct TrackEntry {
        var label: String
        var confidence: Float
        /// Oldest to newest, capped at MotionParameters.historyLength.
        var depthHistory: [Double]
        var horizontalHistory: [Double]
        /// Candidate state accumulating settle frames.
        var pendingState: MotionState
        var settleCount: Int
        /// Confirmed state (published after settleFrames consecutive matching candidates).
        var confirmedState: MotionState
        var framesTracked: Int
        var lastSeenFrame: Int
    }

    private var tracks: [TrackEntry] = []

    // MARK: - Public

    /// Feed new detections for the current frame. Returns one `TrackedObject` per matched detection.
    /// Unmatched tracks are kept in history until `expiryFrames` elapses; stale tracks are dropped.
    func update(detections: [CVDetection], frameIndex: Int) -> [TrackedObject] {
        expireStale(currentFrame: frameIndex)

        var matchedTrackIndices = Set<Int>()
        var result: [TrackedObject] = []

        for detection in detections {
            if let idx = bestMatch(for: detection, excluding: matchedTrackIndices) {
                matchedTrackIndices.insert(idx)
                updateTrack(at: idx, with: detection, frameIndex: frameIndex)
            } else {
                tracks.append(makeEntry(from: detection, frameIndex: frameIndex))
                matchedTrackIndices.insert(tracks.count - 1)
            }
        }

        for idx in matchedTrackIndices {
            guard idx < tracks.count else { continue }
            let entry = tracks[idx]
            let (approachRate, lateralRate) = computeVelocity(for: entry)
            result.append(TrackedObject(
                label: entry.label,
                confidence: entry.confidence,
                horizontalNorm: entry.horizontalHistory.last ?? 0,
                distanceMeters: entry.depthHistory.last ?? -1,
                motionState: entry.confirmedState,
                approachRateMetersPerSecond: approachRate,
                lateralRateNormPerSecond: lateralRate,
                framesTracked: entry.framesTracked
            ))
        }

        return result
    }

    // MARK: - Matching

    private func bestMatch(for detection: CVDetection, excluding: Set<Int>) -> Int? {
        var bestIdx: Int? = nil
        var bestDistance = MotionParameters.matchRadiusNorm

        for (idx, track) in tracks.enumerated() {
            guard !excluding.contains(idx) else { continue }
            guard track.label == detection.label else { continue }
            let d = abs((track.horizontalHistory.last ?? 0) - detection.horizontalNorm)
            if d < bestDistance {
                bestDistance = d
                bestIdx = idx
            }
        }
        return bestIdx
    }

    // MARK: - Track mutation

    private func updateTrack(at idx: Int, with detection: CVDetection, frameIndex: Int) {
        tracks[idx].confidence = detection.confidence
        tracks[idx].lastSeenFrame = frameIndex
        tracks[idx].framesTracked += 1

        appendToHistory(value: detection.horizontalNorm, in: &tracks[idx].horizontalHistory)
        if detection.distanceMeters > 0 {
            appendToHistory(value: detection.distanceMeters, in: &tracks[idx].depthHistory)
        }

        let (approachRate, lateralRate) = computeVelocity(for: tracks[idx])
        let candidate = classify(approachRate: approachRate, lateralRate: lateralRate,
                                 framesTracked: tracks[idx].framesTracked)
        advanceSettle(at: idx, candidate: candidate)
    }

    private func advanceSettle(at idx: Int, candidate: MotionState) {
        if candidate == tracks[idx].pendingState {
            tracks[idx].settleCount += 1
            if tracks[idx].settleCount >= MotionParameters.settleFrames {
                tracks[idx].confirmedState = candidate
            }
        } else {
            tracks[idx].pendingState = candidate
            tracks[idx].settleCount = 1
        }
    }

    // MARK: - Classification

    private func classify(approachRate: Double, lateralRate: Double, framesTracked: Int) -> MotionState {
        guard framesTracked >= 2 else { return .unknown }
        if approachRate >= MotionParameters.approachThresholdMetersPerSecond { return .approaching }
        if approachRate <= -MotionParameters.approachThresholdMetersPerSecond { return .receding }
        if abs(lateralRate) >= MotionParameters.lateralThresholdNormPerSecond { return .moving }
        return .stationary
    }

    // MARK: - Velocity

    private func computeVelocity(for entry: TrackEntry) -> (approachRate: Double, lateralRate: Double) {
        let dCount = entry.depthHistory.count
        let hCount = entry.horizontalHistory.count
        guard dCount >= 2, hCount >= 2 else { return (0, 0) }

        let hz = MotionParameters.detectionHz
        // Depth: positive approach rate means object is getting closer (depth decreasing).
        let depthElapsed = Double(dCount - 1) / hz
        let approachRate = (entry.depthHistory.first! - entry.depthHistory.last!) / depthElapsed

        // Lateral: positive = moving right in portrait space.
        let lateralElapsed = Double(hCount - 1) / hz
        let lateralRate = (entry.horizontalHistory.last! - entry.horizontalHistory.first!) / lateralElapsed

        return (approachRate, lateralRate)
    }

    // MARK: - History helpers

    private func appendToHistory(value: Double, in history: inout [Double]) {
        history.append(value)
        if history.count > MotionParameters.historyLength {
            history.removeFirst()
        }
    }

    private func makeEntry(from detection: CVDetection, frameIndex: Int) -> TrackEntry {
        var depthHistory: [Double] = []
        if detection.distanceMeters > 0 { depthHistory = [detection.distanceMeters] }
        return TrackEntry(
            label: detection.label,
            confidence: detection.confidence,
            depthHistory: depthHistory,
            horizontalHistory: [detection.horizontalNorm],
            pendingState: .unknown,
            settleCount: 0,
            confirmedState: .unknown,
            framesTracked: 1,
            lastSeenFrame: frameIndex
        )
    }

    // MARK: - Expiry

    private func expireStale(currentFrame: Int) {
        tracks.removeAll { currentFrame - $0.lastSeenFrame > MotionParameters.expiryFrames }
    }
}
