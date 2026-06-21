import Foundation

/// API keys for the voice layer, injected at build time.
///
/// Real values live only in `ios/Local.xcconfig` (gitignored) and the build output
/// (also gitignored). They flow into Info.plist as `$(DEEPGRAM_API_KEY)` and
/// `$(ANTHROPIC_API_KEY)`, which Xcode resolves when it processes the plist. The tracked
/// `Sources/Info.plist` only ever holds the literal `$(VAR)`, so no key reaches git.
///
/// A `nil` here means the key was not configured. The voice layer treats that as
/// "voice unavailable" and the rest of the app runs normally, per the degradation table
/// in `docs/14-voice-and-reasoning-plan.md`.
enum Secrets {
    static var deepgramAPIKey: String? { value(for: "DeepgramAPIKey") }
    static var anthropicAPIKey: String? { value(for: "AnthropicAPIKey") }

    /// True when both keys are present, so a caller can gate the voice tier in one check.
    static var voiceConfigured: Bool { deepgramAPIKey != nil && anthropicAPIKey != nil }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means the xcconfig var was blank. A leading "$(" means the build variable
        // was never defined and the placeholder passed through unresolved. Both mean "not set".
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
