import Foundation
import Observation
import os

/// Samples the system thermal state over a run so a soak test produces a timeline, not a guess.
///
/// The demo runs LiDAR depth, GPS, the screen, and the radio together for minutes at a time. Heat
/// builds slowly, so a quick check never sees it. This records the thermal state on a fixed cadence
/// while the operator drives the real load (depth, link, motion) from the other cards, tracks the
/// peak reached and how long was spent in each state, and writes every sample to the unified log
/// so the run can be reviewed after the walk. The degrade thresholds are in
/// `docs/12-perception-and-safety-design.md`.
@MainActor
@Observable
final class ThermalMonitor {
    private(set) var current: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var peak: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isSoaking = false
    private(set) var elapsedSeconds = 0

    /// Wall-clock seconds spent in each state during the current or last soak.
    private(set) var secondsByState: [ProcessInfo.ThermalState: Int] = [:]

    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "com.samuelgerungan.WAND", category: "thermal")
    private let sampleInterval = 2

    var currentLabel: String { Self.label(current) }
    var peakLabel: String { Self.label(peak) }

    /// "nominal 240s, fair 120s, serious 30s" for the states that were actually seen.
    var summary: String {
        let order: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let parts = order.compactMap { state -> String? in
            guard let seconds = secondsByState[state], seconds > 0 else { return nil }
            return "\(Self.label(state)) \(seconds)s"
        }
        return parts.isEmpty ? "no samples yet" : parts.joined(separator: ", ")
    }

    // MARK: - Soak control

    func startSoak() {
        guard !isSoaking else { return }
        let now = ProcessInfo.processInfo.thermalState
        isSoaking = true
        elapsedSeconds = 0
        secondsByState = [:]
        current = now
        peak = now
        log.notice("soak start, thermal \(Self.label(now), privacy: .public)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.sampleInterval ?? 2))
                self?.sample()
            }
        }
    }

    func stopSoak() {
        task?.cancel()
        task = nil
        isSoaking = false
        log.notice("soak stop after \(self.elapsedSeconds)s, peak \(self.peakLabel, privacy: .public); \(self.summary, privacy: .public)")
    }

    // MARK: - Sampling

    private func sample() {
        let state = ProcessInfo.processInfo.thermalState
        current = state
        elapsedSeconds += sampleInterval
        secondsByState[state, default: 0] += sampleInterval
        // ThermalState is an Int-backed enum: nominal 0, fair 1, serious 2, critical 3.
        if state.rawValue > peak.rawValue { peak = state }
        log.info("t+\(self.elapsedSeconds)s thermal \(Self.label(state), privacy: .public)")
    }

    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
