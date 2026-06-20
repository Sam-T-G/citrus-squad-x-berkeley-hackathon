import Foundation
import Network
import os

/// A snapshot of the link, pushed to the UI. Sendable so it can cross from the transmitter
/// actor to the main actor.
struct LinkReport: Sendable {
    var connectionState: String
    var packetsSent: Int
    var lastEvent: String
}

/// Owns the UDP socket to the ESP32 and the 10 Hz heartbeat. An `actor` because two callers
/// touch the staged cue: the staging loop sets it, the heartbeat reads it. The actor serializes
/// both with no locks.
///
/// Every 100 ms the heartbeat sends the staged cue, or an `0x00` idle if nothing is staged.
/// That cadence is what lets the ESP32 fall back to quiet after 500 ms of silence
/// (see `docs/03-protocol.md`). The sequence number rolls so the ESP32 can spot drops.
actor LC2Transmitter {
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "com.samuelgerungan.CitrusSquad.lc2")
    private let report: @Sendable (LinkReport) -> Void
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "lc2")

    private var connection: NWConnection?
    private var heartbeat: Task<Void, Never>?
    private var staged: LC2Packet?
    private var sequence: UInt8 = 0
    private var packetsSent = 0
    private var connectionState = "down"

    init(host: String, port: UInt16, report: @escaping @Sendable (LinkReport) -> Void) {
        self.endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 9999
        )
        self.report = report
    }

    func start() {
        let conn = NWConnection(to: endpoint, using: .udp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state) }
        }
        conn.start(queue: queue)
        startHeartbeat()
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        connection = nil
        connectionState = "down"
        emit(lastEvent: "—")
    }

    /// Stage a cue. The next heartbeat tick sends it. It holds until replaced or cleared.
    func stage(_ packet: LC2Packet) {
        staged = packet
    }

    func clearStaged() {
        staged = nil
    }

    // MARK: - Internals

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(CitrusSquadConfig.heartbeatMilliseconds))
            }
        }
    }

    private func tick() {
        var packet = staged ?? LC2Packet.idle(sequence: sequence)
        packet.sequence = sequence
        sequence &+= 1
        send(packet)
    }

    private func send(_ packet: LC2Packet) {
        guard let connection else { return }
        let data = packet.encoded()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { await self.afterSend(packet, error: error) }
        })
    }

    private func afterSend(_ packet: LC2Packet, error: NWError?) {
        if let error {
            log.error("send failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        packetsSent += 1
        emit(lastEvent: "\(packet.event.label) mask=0x\(String(packet.mask.rawValue, radix: 16))")
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready: connectionState = "ready"
        case .preparing: connectionState = "preparing"
        case .setup: connectionState = "setup"
        case .waiting(let error): connectionState = "waiting: \(error.localizedDescription)"
        case .failed(let error): connectionState = "failed: \(error.localizedDescription)"
        case .cancelled: connectionState = "cancelled"
        @unknown default: connectionState = "unknown"
        }
        emit(lastEvent: "—")
    }

    private func emit(lastEvent: String) {
        report(LinkReport(connectionState: connectionState, packetsSent: packetsSent, lastEvent: lastEvent))
    }
}
