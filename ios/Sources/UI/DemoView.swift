import SwiftUI

/// The demo visualizer: a window into what each phone module sees, for the audience. The wearer is
/// blind, but judges aren't, so this shows the system thinking: position on a map, the camera with
/// the vision model's boxes, the LiDAR depth bands, and the cue the system settled on.
///
/// Each panel is its own view backed by a plug point, so a teammate's work drops in when ready:
/// the map reads the nav data, the camera panel reads `DetectionStore` (Cole), the depth panel
/// reads `DepthService`. Audio (Josh) is audible via the cue stream already.
struct DemoView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cueStrip
                beltPanel
                MapSection(model: model)
                CameraPanel(depth: model.depth, detections: model.detections, interference: model.interference)
                DepthPanel(model: model)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private var beltPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Belt", systemImage: "circle.grid.cross").font(.headline)
            BeltView(mask: model.resolved.mask,
                     accent: ProductionView.visual(for: model.resolved).color)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var cueStrip: some View {
        let visual = ProductionView.visual(for: model.resolved)
        return HStack(spacing: 12) {
            Image(systemName: visual.symbol)
                .font(.title.bold())
                .foregroundStyle(visual.color)
                .contentTransition(.symbolEffect(.replace))
            Text(visual.text)
                .font(.title2.bold())
                .foregroundStyle(visual.color)
            Spacer()
            Text(model.resolved.source.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(visual.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    DemoView(model: AppModel())
}
