import Foundation
import AVFoundation
import os

/// Captures the microphone and exposes it as an `AsyncStream` of 16 kHz mono linear-PCM frames, the
/// format the Deepgram Voice Agent listens in. Bridges AVAudioEngine's tap callback into async at
/// the boundary, per `SWIFT.md`. Confined to the `VoiceSession` actor; not Sendable on purpose.
///
/// VERIFY ON DEVICE: the target rate and encoding here must match the `audio.input` block in the
/// Settings message. Tune both together. The tap closure capture may also need `nonisolated(unsafe)`
/// under strict concurrency, the way `CameraService` handles its session.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "voice.mic")
    private var continuation: AsyncStream<Data>.Continuation?

    private static let targetSampleRate = 16_000.0

    func start() throws -> AsyncStream<Data> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceError.audioFailed("could not build the 16 kHz converter")
        }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            // Runs on an audio render thread. Yielding to an AsyncStream continuation is thread-safe.
            guard let data = Self.convert(buffer, with: converter, to: targetFormat) else { return }
            continuation.yield(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.audioFailed(error.localizedDescription)
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to targetFormat: AVAudioFormat) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// Plays the Deepgram TTS audio chunks the agent sends back. Confined to the `VoiceSession` actor.
///
/// The agent streams 24 kHz mono linear16 (Int16), matching the `audio.output` block in the Settings
/// message. The player node is connected to the mixer in float32, the format AVAudioEngine mixes
/// natively, and each Int16 chunk is converted on the way in (see `buffer(from:)`). A direct Int16
/// mixer connection can play silent on device, so the conversion removes that unknown. If the
/// `audio.output` sample rate ever changes, change the 24 kHz here to match it.
final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var running = false

    init?() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24_000,
                                         channels: 1,
                                         interleaved: false) else { return nil }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ data: Data) {
        guard let buffer = Self.buffer(from: data, format: format) else { return }
        if !running {
            try? engine.start()
            player.play()
            running = true
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
        running = false
    }

    private static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        // The agent sends Int16 linear16; the player node mixes in float32. Scale each sample into
        // [-1, 1] as it copies across.
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = channel[0]
            for index in 0..<Int(frameCount) {
                out[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }
        return buffer
    }
}
