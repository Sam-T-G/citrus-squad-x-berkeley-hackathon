import SwiftUI

/// Top-down view of the belt: four motors around the torso (front, back, left, right). A motor
/// lights up when its bit is set in the current cue's mask, so you can see exactly what the wearer
/// is feeling. Front = forward, Left/Right = rotate, Back = proximity.
struct BeltView: View {
    let mask: QuadrantMask
    var accent: Color = .blue

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                motor("Front", active: mask.contains(.front))
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                motor("Left", active: mask.contains(.left))
                torso
                motor("Right", active: mask.contains(.right))
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                motor("Back", active: mask.contains(.back))
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(8)
        .animation(.easeOut(duration: 0.15), value: mask)
    }

    private var torso: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(.systemGray5))
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "figure.stand")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }

    private func motor(_ label: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(active ? accent : Color(.systemGray5))
                .frame(width: 52, height: 52)
                .overlay {
                    Circle().strokeBorder(active ? accent : Color(.systemGray3), lineWidth: 2)
                }
                .shadow(color: active ? accent.opacity(0.6) : .clear, radius: active ? 10 : 0)
                .scaleEffect(active ? 1.08 : 1.0)
            Text(label)
                .font(.caption2.weight(active ? .bold : .regular))
                .foregroundStyle(active ? accent : .secondary)
        }
        .accessibilityLabel("\(label) motor \(active ? "active" : "off")")
    }
}

#Preview {
    VStack(spacing: 30) {
        BeltView(mask: .right, accent: .blue)
        BeltView(mask: .back, accent: .orange)
        BeltView(mask: .all, accent: .green)
    }
    .padding()
}
