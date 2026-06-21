import Foundation
import AVFoundation
import Observation
import os

/// What the voice layer is doing right now, for the operator UI and for gating.
enum VoiceState: Sendable, Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case unavailable      // keys missing or mic denied; the rest of the app runs normally
    case failed(String)
}

/// The `@MainActor @Observable` face of the voice layer. `AppModel` owns one of these and wires its
/// command handler. It holds UI state and owns the `VoiceSession` actor, which does the I/O.
///
/// Push-to-talk lives here: `startTalking()` on press, `stopTalking()` on release. Keeping the mic
/// closed otherwise is the noise and privacy guard from `docs/14`.
@MainActor
@Observable
final class VoiceModel {
    private(set) var state: VoiceState = .idle
    private(set) var lastTranscript = ""
    private(set) var lastReply = ""

    /// True while the agent has the audio floor (connecting, listening, thinking, or speaking). The
    /// automatic cue narration defers to it so the two voices do not talk over each other.
    var isEngaged: Bool {
        switch state {
        case .connecting, .listening, .thinking, .speaking: return true
        case .idle, .unavailable, .failed: return false
        }
    }

    /// Set by `AppModel`: run a command, return the line the agent should speak.
    var handler: VoiceSession.CommandHandler?

    private var session: VoiceSession?
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "voice.model")

    /// Voice needs the Deepgram key to talk. The think stage runs on Deepgram-managed `gpt-4o-mini`
    /// (no key of ours), so the agent connects on the Deepgram key alone. Our Anthropic key powers the
    /// separate on-device draft-and-verify and vision path, not this socket.
    var isConfigured: Bool { Secrets.deepgramAPIKey != nil }

    // MARK: - Control

    /// Tap to start a listening session; tap again while it is active to end it early. The agent
    /// responds on its own when the speaker pauses (Deepgram detects end-of-speech from the
    /// continuous audio), so there is no separate "send" tap.
    func toggle() async {
        switch state {
        case .idle, .failed, .unavailable: await startTalking()
        default: await stop()
        }
    }

    func stop() async {
        await session?.stop()
    }

    func startTalking() async {
        guard let key = Secrets.deepgramAPIKey, let handler else {
            state = .unavailable
            return
        }
        guard await Self.ensureMicPermission() else {
            state = .failed("microphone permission denied")
            return
        }
        await session?.stop()
        state = .connecting
        let session = VoiceSession(
            apiKey: key,
            report: { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            },
            handle: handler
        )
        self.session = session
        await session.start()
    }

    // MARK: - Internals

    private func apply(_ update: VoiceUpdate) {
        switch update {
        case .state(let next): state = next
        case .transcript(let text): lastTranscript = text
        case .reply(let text): lastReply = text
        }
    }

    private static func ensureMicPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
