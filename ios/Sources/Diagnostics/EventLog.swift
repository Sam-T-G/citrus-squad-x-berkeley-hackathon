import Foundation
import Observation

/// One line in the debug event log.
struct LoggedEvent: Identifiable, Sendable {
    let id: Int
    let time: String
    let tag: String
    let detail: String
}

/// A small in-app event log for debugging what the decide loop is doing on device, where a console
/// is not handy. Entries are deduped per tag by a caller-supplied key, so a steady state (the same
/// cue every tick at 10 Hz) records once instead of flooding; a transition records a fresh line with
/// the values at that moment. Capped to a ring so it never grows without bound.
@MainActor
@Observable
final class EventLog {
    private(set) var events: [LoggedEvent] = []
    private var nextID = 0
    private var lastKeyByTag: [String: String] = [:]
    private let cap = 300

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Append an event. When `dedupKey` is given, repeats of the same tag+key are skipped, so only
    /// state changes are recorded.
    func log(_ tag: String, _ detail: String, dedupKey: String? = nil) {
        if let dedupKey {
            if lastKeyByTag[tag] == dedupKey { return }
            lastKeyByTag[tag] = dedupKey
        }
        events.append(LoggedEvent(id: nextID, time: formatter.string(from: Date()), tag: tag, detail: detail))
        nextID += 1
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    func clear() {
        events.removeAll()
        lastKeyByTag.removeAll()
    }

    /// The whole log as plain text, newest last, for copying off the device.
    func exportText() -> String {
        events.map { "\($0.time)  [\($0.tag)] \($0.detail)" }.joined(separator: "\n")
    }
}
