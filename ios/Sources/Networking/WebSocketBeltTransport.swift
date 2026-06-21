import Foundation
import os

/// The two ways the phone can reach the belt link. Both speak the same 4-byte LC2 frames and the
/// same 10 Hz heartbeat; only the wire underneath differs. `LC2Transmitter` (UDP, the original plan)
/// stays the default; `WebSocketBeltTransport` is the internet fallback for when the phone and the
/// laptop cannot share a network.
///
/// `LC2Transmitter` already has every method this requires, so it conforms with no code change (the
/// extension below). `AppModel` holds an `any BeltTransport` and picks the concrete type at link
/// start, so the rest of the app never learns which wire is in use.
protocol BeltTransport: Actor {
    func start()
    func stop()
    func stage(_ packet: LC2Packet)
    func clearStaged()
}

/// The original UDP transmitter is already a drop-in: same method names, same behaviour.
extension LC2Transmitter: BeltTransport {}

/// Sends the LC2 cue stream to a hosted relay over a WebSocket, for the internet fallback path. The
/// phone connects out to `wss://<relay>/send` (port 443, which networks almost never block); the
/// relay forwards each frame to the laptop's `relay_client.py`, which drives the Arduino. Mirrors
/// `LC2Transmitter`: a 10 Hz heartbeat sends the staged cue, or an idle when nothing is staged, and
/// reconnects on its own if the link drops.
actor WebSocketBeltTransport: BeltTransport {
    /// The Fly.io relay from `server/fly.toml`. Override per deploy; the `/send` role is the phone's.
    static let defaultRelayURL = "wss://citrus-squad-belt-relay.fly.dev/send"

    private let url: URL?
    private let report: @Sendable (LinkReport) -> Void
    private let session = URLSession(configuration: .default)
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "belt-ws")

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var staged: LC2Packet?
    private var sequence: UInt8 = 0
    private var packetsSent = 0
    private var connectionState = "down"
    private var running = false

    init(urlString: String, report: @escaping @Sendable (LinkReport) -> Void) {
        self.url = URL(string: urlString)
        self.report = report
    }

    func start() {
        guard url != nil else {
            connectionState = "bad relay URL"
            emit(lastEvent: "—")
            return
        }
        running = true
        connect()
        startHeartbeat()
    }

    func stop() {
        running = false
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionState = "down"
        emit(lastEvent: "—")
    }

    func stage(_ packet: LC2Packet) { staged = packet }
    func clearStaged() { staged = nil }

    // MARK: - Connection

    private func connect() {
        guard running, let url else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        connectionState = "connecting"
        emit(lastEvent: "—")
        // A receive loop keeps the socket alive and surfaces a drop. We never read belt data back, so
        // anything received is ignored; only the failure path matters.
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success:
            receiveLoop()
        case .failure(let error):
            log.error("ws receive failed: \(error.localizedDescription, privacy: .public)")
            reconnectSoon()
        }
    }

    private func reconnectSoon() {
        guard running else { return }
        connectionState = "reconnecting"
        emit(lastEvent: "—")
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.connect()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(CitrusSquadConfig.heartbeatMilliseconds))
            }
        }
    }

    private func tick() async {
        guard let task else { return }
        var packet = staged ?? LC2Packet.idle(sequence: sequence)
        packet.sequence = sequence
        sequence &+= 1
        do {
            try await task.send(.data(packet.encoded()))
            packetsSent += 1
            connectionState = "ready"
            emit(lastEvent: "\(packet.event.label) mask=0x\(String(packet.mask.rawValue, radix: 16))")
        } catch {
            log.error("ws send failed: \(error.localizedDescription, privacy: .public)")
            reconnectSoon()
        }
    }

    private func emit(lastEvent: String) {
        report(LinkReport(connectionState: connectionState, packetsSent: packetsSent, lastEvent: lastEvent))
    }
}
