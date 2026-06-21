import Foundation
import os

/// Direct calls to the Anthropic Messages API (`/v1/messages`) over `URLSession`. There is no official
/// Anthropic Swift SDK, so this is raw HTTP, exactly what `docs/14-voice-and-reasoning-plan.md` and
/// `AI-USAGE-AUDIT-AND-EXPANSION.md` specified.
///
/// Everything here is off the belt's safety path. The belt cues come from LiDAR geometry on-device and
/// never wait on this. Every failure path returns `nil`, and the caller falls back to a hardcoded,
/// sensor-grounded line. A slow or failed request can drop a spoken sentence; it can never stall the
/// belt or the heartbeat.
///
/// An `actor` so the key read and the request building serialize cleanly, and so a call can never run
/// on the 10 Hz decide loop. The key is read fresh on each call from `Secrets`, so rotating the key in
/// `Local.xcconfig` and rebuilding is enough; nothing caches it.
actor ClaudeClient {
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "claude")

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
    /// Pinned API version. Anthropic dates this header; `2023-06-01` is the stable Messages API.
    private static let apiVersion = "2023-06-01"

    /// True when an Anthropic key is configured. The whole tier gates on this in one check, so the app
    /// runs normally with the key absent (the spoken tier just uses its grounded fallback strings).
    var isConfigured: Bool { Secrets.anthropicAPIKey != nil }

    // MARK: - High-level draft and verify (Slice A)

    /// Draft one spoken line from the structured scene, fast and cheap. The line is a candidate only;
    /// it is never spoken until `verify` checks it against the same snapshot. Returns `nil` on any
    /// failure so the caller speaks its grounded fallback.
    func draftLine(systemPrompt: String, snapshotXML: String,
                   instruction: String) async -> String? {
        let user = "\(snapshotXML)\n\n\(instruction)"
        let request = Request(model: CitrusSquadConfig.claudeDraftModel,
                              system: systemPrompt, userText: user)
        return await firstText(for: request)
    }

    /// Verify a drafted line against the snapshot. The verifier returns structured output so we get a
    /// parseable verdict instead of free text: `approved` plus the line to speak (the verifier may
    /// tighten the phrasing). Returns `nil` on failure; a `nil` or unapproved verdict means speak the
    /// grounded fallback, never the unverified draft.
    func verify(systemPrompt: String, snapshotXML: String, draft: String) async -> VerifiedLine? {
        let user = """
        \(snapshotXML)

        A drafter proposed this spoken line:
        "\(draft)"

        Check it against the scene above. Approve it only if every claim is supported by the data. If
        it claims a clear path the distances do not support, names something not in the scene, or the
        confidence is low and it sounds certain, reject it. You may tighten the wording.
        """
        let request = Request(model: CitrusSquadConfig.claudeVerifyModel,
                              system: systemPrompt, userText: user,
                              jsonSchema: VerifiedLine.schema)
        guard let json = await firstText(for: request),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VerifiedLine.self, from: data)
    }

    // MARK: - High-level vision (Slice B)

    /// Read or describe a single camera frame. Pull-based: the caller grabs one frame and hands it
    /// here, never a stream. `imageJPEG` is one base64-able JPEG. Opus is the default for small-text
    /// reads (street signs, bus numbers); pass a cheaper model for plain scene description. Returns the
    /// spoken line, or `nil` on failure.
    func describeFrame(systemPrompt: String, instruction: String,
                       imageJPEG: Data,
                       model: String = CitrusSquadConfig.claudeVisionModel) async -> String? {
        let request = Request(model: model, system: systemPrompt,
                              userText: instruction, imageJPEG: imageJPEG)
        return await firstText(for: request)
    }

    // MARK: - Request

    /// One Messages API request. `userText` is the text block; `imageJPEG`, when set, becomes a base64
    /// image block placed before the text (the order Anthropic's vision guidance recommends).
    /// `jsonSchema`, when set, constrains the response to that schema so the first text block is valid
    /// JSON we can decode without scraping free text.
    private struct Request {
        var model: String
        var system: String
        var userText: String
        var imageJPEG: Data?
        var jsonSchema: [String: Any]?
        var maxTokens = CitrusSquadConfig.claudeMaxTokens
    }

    /// Build, send, and pull the first text block out of the response. Returns `nil` on a missing key,
    /// a non-200, a transport error, a timeout, a refusal, or any decode miss. The belt is unaffected
    /// by every one of these.
    private func firstText(for request: Request) async -> String? {
        guard let apiKey = Secrets.anthropicAPIKey else {
            log.debug("claude skipped: no key configured")
            return nil
        }
        guard let endpoint = Self.endpoint, let body = Self.encodeBody(request) else {
            log.error("claude request build failed")
            return nil
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = CitrusSquadConfig.claudeTimeoutSeconds
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                log.error("claude HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
            return Self.decodeFirstText(data)
        } catch {
            log.error("claude request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Serialize the request body. Built with `JSONSerialization` because the schema and content blocks
    /// are heterogeneous `[String: Any]`; a `Codable` model would fight the dynamic `jsonSchema`.
    private static func encodeBody(_ request: Request) -> Data? {
        // The system prompt gets a cache breakpoint. The reasoning contract is frozen, so once it is
        // long enough to cache (2048 tokens on Haiku/Sonnet, 4096 on Opus) repeated calls read it back
        // cheaply. Below that minimum the breakpoint is a silent no-op, which is harmless.
        let system: [[String: Any]] = [[
            "type": "text",
            "text": request.system,
            "cache_control": ["type": "ephemeral"],
        ]]

        var content: [[String: Any]] = []
        if let jpeg = request.imageJPEG {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    // No line breaks: base64EncodedString() emits none by default.
                    "data": jpeg.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": request.userText])

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        if let schema = request.jsonSchema {
            // output_config.format guarantees the first text block is JSON matching the schema (GA, no
            // beta header). The verifier uses this so we decode a verdict instead of parsing prose.
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Pull the first `text` content block out of a Messages response. A refusal arrives as HTTP 200
    /// with `stop_reason: "refusal"` and no usable text, so we return `nil` and fall back; the same
    /// happens for any unexpected shape.
    private static func decodeFirstText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let stop = json["stop_reason"] as? String, stop == "refusal" { return nil }
        guard let content = json["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "text" {
            if let text = block["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }
}

/// The verifier's structured verdict. `approved` gates whether the line is spoken at all; `phrase` is
/// the line to speak when approved (the verifier may tighten the drafter's wording).
struct VerifiedLine: Decodable, Sendable {
    let approved: Bool
    let phrase: String

    /// The JSON schema handed to `output_config.format`. `additionalProperties: false` and both keys
    /// required, as structured outputs demand. Computed (not stored) so it stays clear of Swift 6's
    /// concurrency-safety rule for non-`Sendable` static storage.
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "approved": ["type": "boolean"],
                "phrase": ["type": "string"],
            ],
            "required": ["approved", "phrase"],
            "additionalProperties": false,
        ]
    }
}
