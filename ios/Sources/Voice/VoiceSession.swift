import Foundation
import AVFoundation
import os

/// Sendable updates the session pushes to the main actor. Mirrors how `LC2Transmitter` reports a
/// `LinkReport`: the actor owns the I/O, a closure marshals state to `@MainActor`.
enum VoiceUpdate: Sendable {
    case state(VoiceState)
    case transcript(String)   // what the wearer said
    case reply(String)        // what the agent spoke back
}

/// Owns the Deepgram Voice Agent WebSocket and the audio I/O. An `actor` because the send loop and
/// the receive loop both touch the socket and session state; the actor serializes them with no lock.
///
/// Flow: connect, send Settings, stream mic frames up, then handle two things coming down: TTS audio
/// (play it) and client-side function-call requests (run on-device, send a response). None of this
/// is on the belt's safety path. If the whole session dies, navigation and the LiDAR reflex keep
/// running, which is the contract in `docs/14-voice-and-reasoning-plan.md`.
actor VoiceSession {
    typealias CommandHandler = @MainActor @Sendable (VoiceCommand) async -> String

    private let apiKey: String
    private let report: @Sendable (VoiceUpdate) -> Void
    private let handle: CommandHandler
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "voice")

    private let mic = MicCapture()
    private let speaker = TTSPlayer()
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var micPump: Task<Void, Never>?
    private var closeTimer: Task<Void, Never>?
    private var agentSpeaking = false

    // VERIFY ON DEVICE: endpoint and auth header against the current Voice Agent docs.
    private static let endpoint = URL(string: "wss://agent.deepgram.com/v1/agent/converse")

    init(apiKey: String,
         report: @escaping @Sendable (VoiceUpdate) -> Void,
         handle: @escaping CommandHandler) {
        self.apiKey = apiKey
        self.report = report
        self.handle = handle
    }

    // MARK: - Lifecycle

    func start() async {
        report(.state(.connecting))
        do {
            try configureAudioSession()
            try connect()
            await sendSettings()
            listen()
            try startMic()
            report(.state(.listening))
        } catch {
            log.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            report(.state(.failed("\(error)")))
            await stop()
        }
    }

    func stop() async {
        closeTimer?.cancel(); closeTimer = nil
        micPump?.cancel(); micPump = nil
        receiveLoop?.cancel(); receiveLoop = nil
        mic.stop()
        speaker?.stop()
        if socket != nil {
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
        }
        report(.state(.idle))
    }

    private func scheduleClose(after delay: Duration) {
        closeTimer?.cancel()
        closeTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.stop()
        }
    }

    // MARK: - Connection

    private func connect() throws {
        guard let endpoint = Self.endpoint else { throw VoiceError.connectionFailed("bad endpoint URL") }
        var request = URLRequest(url: endpoint)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
    }

    private func configureAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        do {
            // Plain .default mode (not .voiceChat/.videoChat) stops iOS from treating this as a phone
            // call and routing to the quiet earpiece. We give up hardware echo cancellation, but the
            // agentSpeaking mic-mute already keeps the agent from hearing itself. Force the loud
            // bottom speaker explicitly.
            try audio.setCategory(.playAndRecord,
                                  mode: .default,
                                  options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true)
            try? audio.overrideOutputAudioPort(.speaker)
        } catch {
            throw VoiceError.audioFailed(error.localizedDescription)
        }
    }

    private func startMic() throws {
        let frames = try mic.start()
        micPump = Task { [weak self] in
            for await frame in frames {
                guard let self else { break }
                await self.send(audio: frame)
            }
        }
    }

    // MARK: - Receive

    private func listen() {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let message = try? await self.nextMessage() else { break }
                await self.process(message)
            }
        }
    }

    private func nextMessage() async throws -> URLSessionWebSocketTask.Message? {
        guard let socket else { return nil }
        return try await socket.receive()
    }

    private func process(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .data(let data):
            agentSpeaking = true            // mute our mic so we do not transcribe the agent's voice
            speaker?.play(data)             // a TTS audio chunk
            report(.state(.speaking))
        case .string(let text):
            await handleEvent(text)
        @unknown default:
            break
        }
    }

    /// VERIFY ON DEVICE: the event `type` values and field names below are from the Voice Agent
    /// docs. Log raw frames once on the phone and adjust if any name differs.
    private func handleEvent(_ text: String) async {
        log.debug("voice rx: \(text, privacy: .public)")   // V0: confirm the wire schema on device
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "SettingsApplied":
            log.info("voice settings applied")
        case "FunctionCallRequest":
            await dispatchFunctions(json)
        case "ConversationText":
            if let role = json["role"] as? String, let content = json["content"] as? String {
                report(role == "user" ? .transcript(content) : .reply(content))
            }
        case "UserStartedSpeaking":
            report(.state(.listening))
        case "AgentStartedSpeaking":
            report(.state(.speaking))
        case "AgentAudioDone":
            agentSpeaking = false
            scheduleClose(after: .seconds(2))   // let the last audio drain, then close
        case "Error", "Warning":
            let detail = json["description"] as? String ?? type
            log.error("voice agent \(type, privacy: .public): \(detail, privacy: .public)")
            if type == "Error" {
                report(.state(.failed(detail)))
                await stop()
            }
        default:
            break
        }
    }

    // MARK: - Functions

    private func dispatchFunctions(_ json: [String: Any]) async {
        // Deepgram may batch calls. VERIFY ON DEVICE: the envelope ("functions" array, each with
        // id / name / arguments-as-JSON-string).
        let calls = (json["functions"] as? [[String: Any]]) ?? [json]
        for call in calls {
            guard let name = call["name"] as? String else { continue }
            let id = call["id"] as? String ?? ""
            let command = VoiceCommand(functionName: name, arguments: Self.decodeArguments(call["arguments"]))
            report(.state(.thinking))
            let result = await handle(command)
            await sendFunctionResponse(id: id, name: name, content: result)
            report(.reply(result))
        }
    }

    private static func decodeArguments(_ raw: Any?) -> [String: String] {
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.compactMapValues { "\($0)" }
        }
        if let object = raw as? [String: Any] {
            return object.compactMapValues { "\($0)" }
        }
        return [:]
    }

    private func sendFunctionResponse(id: String, name: String, content: String) async {
        await send(json: [
            "type": "FunctionCallResponse",
            "id": id,
            "name": name,
            "content": content,
        ])
    }

    // MARK: - Send

    /// VERIFY ON DEVICE: this Settings shape must match the current Voice Agent docs, and the audio
    /// rates must match `MicCapture` (16 kHz in) and `TTSPlayer` (24 kHz out).
    private func sendSettings() async {
        await send(json: [
            "type": "Settings",
            "audio": [
                "input": ["encoding": "linear16", "sample_rate": 16_000],
                "output": ["encoding": "linear16", "sample_rate": 24_000, "container": "none"],
            ],
            "agent": [
                "listen": ["provider": ["type": "deepgram", "model": "nova-3"]],
                // Deepgram-managed OpenAI model (no endpoint, no key handed to Deepgram). The most
                // reliably available managed think model. Claude is used for the V3 on-device
                // evaluator with our own key, which is the cleaner Anthropic integration anyway.
                "think": [
                    "provider": ["type": "open_ai", "model": "gpt-4o-mini"],
                    "prompt": Self.systemPrompt,
                    "functions": VoiceFunction.allSpecs,
                ],
                "speak": ["provider": ["type": "deepgram", "model": "aura-2-thalia-en"]],
            ],
        ])
    }

    private func send(audio: Data) async {
        guard !agentSpeaking, let socket else { return }   // do not feed the agent its own voice back
        try? await socket.send(.data(audio))
    }

    private func send(json: [String: Any]) async {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        do { try await socket.send(.string(text)) }
        catch { log.error("voice send failed: \(error.localizedDescription, privacy: .public)") }
    }

    private static let systemPrompt = """
    You are the voice of a haptic navigation belt for a blind walker. Keep replies short, calm, and \
    meant to be heard, not read. You have functions to report the wearer's current location, the \
    route status, and the surroundings, and to set a destination, recalibrate, or stop. Always call \
    the matching function to answer a request instead of guessing or saying you cannot. Never invent \
    surroundings or claim a path is clear unless a function told you so.
    """
}
