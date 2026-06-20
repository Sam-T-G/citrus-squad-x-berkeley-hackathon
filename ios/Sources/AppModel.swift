import Foundation
import Observation
import os

/// Top of the app. Owns the sensor services, the route engine, and the LC2 transmitter,
/// and runs the staging loop that turns "where am I pointed" into "which quadrant taps next."
///
/// The transmitter owns the 100 ms heartbeat. This loop runs at 10 Hz and only decides what
/// to stage. Keeping the decide loop and the send loop apart means a slow decision never
/// stalls the heartbeat. See `docs/04-phone-side.md` and `IOS-APP-PLAN.md`.
@MainActor
@Observable
final class AppModel {
    let location = LocationService()
    let motion = MotionService()
    let depth = DepthService()
    let route = RouteEngine()

    /// Where the ESP32 is listening. Editable from the control panel.
    var espHost: String = "192.168.4.1"
    var espPort: UInt16 = 9999

    /// Provisional. When on, an active LiDAR obstacle takes priority over the route cue for that
    /// heartbeat. Toggle it off to test pure route cues. See `docs/03-protocol.md` obstacle tier.
    var obstacleCuesEnabled = true

    private(set) var link = LinkReport(connectionState: "down", packetsSent: 0, lastEvent: "—")
    private(set) var transmitting = false

    private var transmitter: LC2Transmitter?
    private var loop: Task<Void, Never>?
    private let log = Logger(subsystem: "com.samuelgerungan.WAND", category: "app")

    // MARK: - Link control

    func startLink() {
        guard !transmitting else { return }
        let tx = LC2Transmitter(host: espHost, port: espPort) { [weak self] report in
            Task { @MainActor in self?.link = report }
        }
        transmitter = tx
        Task { await tx.start() }
        transmitting = true
        startStagingLoop()
        log.info("link started to \(self.espHost, privacy: .public):\(self.espPort)")
    }

    func stopLink() {
        loop?.cancel()
        loop = nil
        if let tx = transmitter {
            Task { await tx.stop() }
        }
        transmitter = nil
        transmitting = false
    }

    // MARK: - Operator actions

    /// Capture the phone-forward to body-forward offset. See `docs/04-phone-side.md` calibration.
    func calibrate() {
        guard location.trueHeading >= 0 else { return }
        route.calibrate(phoneHeading: location.trueHeading)
    }

    /// Fire one known cue so we can confirm the belt reacts. This is the M0 "hello packet" check.
    func sendTestCue() {
        stage(Cue(event: .turnNow, mask: .right))
    }

    // MARK: - Staging loop

    private func startStagingLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tick() {
        // Provisional Tier-1: an active LiDAR obstacle takes priority over the route cue.
        if obstacleCuesEnabled, depth.isRunning, depth.obstacleAhead {
            stage(Cue(event: .obstacleNear, mask: .centerMass))
            return
        }
        guard location.trueHeading >= 0 else {
            clearStaged()
            return
        }
        route.update(phoneHeading: location.trueHeading)
        if let cue = route.currentCue {
            stage(cue)
        } else {
            clearStaged()
        }
    }

    private func stage(_ cue: Cue) {
        guard let tx = transmitter else { return }
        let packet = LC2Packet(event: cue.event, mask: cue.mask, intensity: LC2Packet.defaultIntensity)
        Task { await tx.stage(packet) }
    }

    private func clearStaged() {
        guard let tx = transmitter else { return }
        Task { await tx.clearStaged() }
    }
}
