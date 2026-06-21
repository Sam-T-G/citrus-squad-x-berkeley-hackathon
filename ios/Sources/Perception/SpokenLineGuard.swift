import Foundation

/// Local, instant guards on a Claude-drafted spoken line. They run on-device with no second API call,
/// and they catch the two outputs that are actually dangerous to a blind listener who cannot see to
/// check them: a false "the way is clear" when the LiDAR says something is close, and a confident
/// distance the model was told never to state. Anything they catch falls back to a safe line.
///
/// They are deliberately biased toward doubt: when the sensors show something close, the burden is on
/// the drafted line to acknowledge it, not on this code to have anticipated every cheerful phrasing.
enum SpokenLineGuard {
    /// Phrasings that assert an open path or invite the wearer to move on. Broad on purpose: when a
    /// close obstacle exists, any of these reaching the wearer is a false all-clear, the worst failure
    /// mode in this domain, so the list errs toward catching too much rather than too little.
    private static let clearClaims = [
        "clear", "all clear", "nothing ahead", "nothing in your", "nothing in the way",
        "nothing's there", "nothing there", "path is open", "way is open", "way forward is fine",
        "way is fine", "good to go", "you're clear", "you are clear", "no obstacle", "all good",
        "you're good", "you are good", "safe to walk", "safe to go", "safe to proceed",
        // affirmative-movement phrasings that imply clear even without the word "clear"
        "keep walking", "keep going", "keep moving", "go ahead", "go straight", "you can go",
        "you can keep", "you can walk", "feel free to walk", "proceed", "carry on",
    ]

    /// True when the line does not claim a clear path the snapshot contradicts. When a close obstacle
    /// exists, any clear-or-go phrasing is rejected. When nothing is close, every line passes.
    static func isConsistent(_ line: String, with snapshot: PerceptionSnapshot) -> Bool {
        guard snapshot.hasCloseObstacle else { return true }
        let lower = line.lowercased()
        return !clearClaims.contains { lower.contains($0) }
    }

    /// Strip a stated metric distance from a vision read, the one thing the read contract forbids and
    /// the thing vision models are documented worst at. The model is told not to state a distance; this
    /// enforces it in code if the model slips, so a confident wrong "about twenty feet ahead" can never
    /// reach a wearer who would act on it. Keeps the rest of the line (the coarse direction survives).
    static func withoutVisionDistance(_ line: String) -> String {
        let pattern = #"(?i)\s*\b(about|around|roughly|approximately|maybe)?\s*\d+(\.\d+)?\s*(feet|foot|ft|meters?|metres?|m|yards?|yds?|yd|inches|inch|in)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(line.startIndex..., in: line)
        let stripped = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
        // Tidy the seams a removed clause leaves behind.
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: ",.", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
