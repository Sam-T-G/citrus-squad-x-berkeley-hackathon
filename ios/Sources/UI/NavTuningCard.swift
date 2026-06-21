import SwiftUI

/// Operator-only live tuning for the navigation cue tolerance. It lives in the Diagnostics tab, so
/// judges never see it. Dial the belt smoothing on a walk without a rebuild, then leave it where it
/// feels right, or tap Reset before a demo run to drop back to the shipped defaults. The values flow
/// straight into the smoother (`model.route.tuning`) on the next tick.
///
/// Navigation only. The person and LiDAR hazard tiers preempt navigation and are untouched by these
/// knobs. See `ios/TOLERANCE-HANDOFF.md` for what each one does.
struct NavTuningCard: View {
    let model: AppModel

    var body: some View {
        @Bindable var tuning = model.route.tuning
        return Card(title: "Nav tolerance (live)", status: .pending) {
            Stepper(value: $tuning.dwellTicks, in: 1...6) {
                LabeledRow("Nudge dwell", "\(tuning.dwellTicks) ticks · ~\(tuning.dwellTicks * 100) ms")
            }
            Stepper(value: $tuning.turnDwellTicks, in: 1...5) {
                LabeledRow("Turn dwell", "\(tuning.turnDwellTicks) ticks · ~\(tuning.turnDwellTicks * 100) ms")
            }
            sliderRow("Escalation", value: $tuning.escalationDegrees, range: 20...180)
            sliderRow("Adjacent deadband", value: $tuning.adjacentMarginDegrees, range: 0...20)
            sliderRow("Turn-around deadband", value: $tuning.turnAroundMarginDegrees, range: 0...30)

            Text("Steadies the turn cue only. Higher dwell and deadband ride out wobble but act slower; lower is snappier. Keep turn dwell at 2 or more. Hazards are never affected.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset to defaults") { tuning.reset() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("default 3 / 2 / 60° / 5° / 10°")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledRow(title, String(format: "%.0f°", value.wrappedValue))
            Slider(value: value, in: range, step: 1)
        }
    }
}

#Preview {
    ScrollView { NavTuningCard(model: AppModel()).padding() }
}
