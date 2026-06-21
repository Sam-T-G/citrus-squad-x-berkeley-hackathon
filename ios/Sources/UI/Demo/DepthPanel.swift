import SwiftUI

/// Visualizes the three LiDAR depth bands so you can see what the obstacle layer sees: a bar per
/// band (left, center, right), shorter and redder as something gets closer. Functional today.
struct DepthPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Depth (LiDAR)", systemImage: "ruler").font(.headline)

            if model.depth.isRunning {
                HStack(alignment: .bottom, spacing: 12) {
                    bar("Left", model.depth.bands.left)
                    bar("Center", model.depth.bands.center)
                    bar("Right", model.depth.bands.right)
                }
                .frame(height: 140)
                Text(hazardText)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.depth.obstacleAhead ? .orange : .secondary)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .frame(height: 140)
                    .overlay {
                        Text(model.depth.isSupported ? "Depth stopped" : "No LiDAR on this device")
                            .foregroundStyle(.secondary)
                    }
            }

            HStack {
                if model.depth.isRunning {
                    Button("Stop") { model.depth.stop() }.buttonStyle(.bordered)
                } else {
                    Button("Start depth") { model.depth.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.depth.isSupported)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// A bar whose height shrinks as the reading gets closer, capped at the threshold range.
    private func bar(_ title: String, _ meters: Double) -> some View {
        let threshold = model.depth.thresholdMeters
        let fraction = meters <= 0 ? 1.0 : min(1.0, meters / (threshold * 2))
        let close = meters > 0 && meters <= threshold
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 6)
                .fill(close ? Color.orange : Color.blue)
                .frame(height: max(8, 120 * fraction))
            Text(meters <= 0 ? "—" : String(format: "%.1fm", meters))
                .font(.caption2.monospaced())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var hazardText: String {
        guard let hazard = model.depth.currentHazard else { return "clear" }
        return String(format: "obstacle %.1f m, mask 0x%X", hazard.distanceMeters, hazard.mask.rawValue)
    }
}
