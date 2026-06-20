import SwiftUI

/// Pass / pending / fail state for a subsystem card. Color is paired with a text label so the
/// status is never color-only, per the accessibility rules in `SWIFT.md`.
enum CardStatus {
    case pass
    case pending
    case fail

    var color: Color {
        switch self {
        case .pass: return .green
        case .pending: return .yellow
        case .fail: return .red
        }
    }

    var label: String {
        switch self {
        case .pass: return "OK"
        case .pending: return "…"
        case .fail: return "FAIL"
        }
    }
}

/// A titled card with a status chip. Reused across every subsystem panel.
struct Card<Content: View>: View {
    let title: String
    let status: CardStatus
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(status.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(status.color.opacity(0.2))
                    .foregroundStyle(status.color)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("\(title) status \(status.label)")
            }
            content
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Label on the left, monospaced value on the right.
struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}
