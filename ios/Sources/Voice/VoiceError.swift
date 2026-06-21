import Foundation

/// Errors from the voice subsystem. Typed per `SWIFT.md`, so callers switch on a case instead of
/// matching strings.
enum VoiceError: Error, CustomStringConvertible {
    case notConfigured
    case microphoneDenied
    case connectionFailed(String)
    case audioFailed(String)

    var description: String {
        switch self {
        case .notConfigured: return "voice API keys are not set"
        case .microphoneDenied: return "microphone permission was denied"
        case .connectionFailed(let detail): return "voice connection failed: \(detail)"
        case .audioFailed(let detail): return "audio engine failed: \(detail)"
        }
    }
}
