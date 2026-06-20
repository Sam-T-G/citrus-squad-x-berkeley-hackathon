import SwiftUI
import CoreLocation

/// The operator screen. One card per subsystem: link, nav bench, heading, GPS, depth, motion.
/// This is the M0-M4 driver: start the link, calibrate, set a target bearing, rotate the phone,
/// and confirm the right cue transmits.
struct ControlPanelView: View {
    @State private var model = AppModel()

    var body: some View {
        @Bindable var model = model
        @Bindable var route = model.route

        ScrollView {
            VStack(spacing: 16) {
                header
                linkCard(host: $model.espHost, port: $model.espPort)
                navCard(bearing: $route.targetRouteBearing)
                headingCard
                gpsCard
                depthCard
                motionCard
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("WAND").font(.largeTitle.bold())
            Text("Citrus Squad — phone-side control").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top)
    }

    // MARK: - Link

    private func linkCard(host: Binding<String>, port: Binding<UInt16>) -> some View {
        Card(title: "Belt link (LC2 / UDP)", status: linkStatus) {
            HStack {
                TextField("ESP32 host", text: host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(model.transmitting)
                TextField("port", value: port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .keyboardType(.numberPad)
                    .disabled(model.transmitting)
            }
            LabeledRow("State", model.link.connectionState)
            LabeledRow("Packets sent", "\(model.link.packetsSent)")
            LabeledRow("Last event", model.link.lastEvent)

            HStack {
                if model.transmitting {
                    Button("Stop link") { model.stopLink() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start link") { model.startLink() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Send test cue") { model.sendTestCue() }
                    .buttonStyle(.bordered)
                    .disabled(!model.transmitting)
            }
        }
    }

    // MARK: - Nav bench

    private func navCard(bearing: Binding<Double>) -> some View {
        Card(title: "Nav bench", status: model.route.currentCue == nil ? .pending : .pass) {
            LabeledRow("Calibrated", model.route.isCalibrated
                ? "yes (offset \(format(model.route.calibrationOffset))°)"
                : "no")
            LabeledRow("Body heading", "\(format(model.route.bodyHeading))°")
            VStack(alignment: .leading) {
                Text("Target route bearing: \(format(model.route.targetRouteBearing))°")
                    .foregroundStyle(.secondary)
                Slider(value: bearing, in: 0...359)
            }
            LabeledRow("Current cue", cueText)
            Button("Calibrate forward") { model.calibrate() }
                .buttonStyle(.borderedProminent)
                .disabled(model.location.trueHeading < 0)
        }
    }

    private var cueText: String {
        guard let cue = model.route.currentCue else { return "centerline (no tap)" }
        return "\(cue.event.label) mask=0x\(String(cue.mask.rawValue, radix: 16))"
    }

    // MARK: - Heading

    private var headingCard: some View {
        Card(title: "Heading", status: headingStatus) {
            LabeledRow("Permission", authText(model.location.authorization))
            LabeledRow("True heading", "\(format(model.location.trueHeading))°")
            LabeledRow("Accuracy", "±\(format(model.location.headingAccuracy))°")
            if model.location.authorization == .notDetermined {
                Button("Request location permission") { model.location.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - GPS

    private var gpsCard: some View {
        Card(title: "GPS", status: gpsStatus) {
            if let loc = model.location.location {
                LabeledRow("Latitude", String(format: "%.6f", loc.coordinate.latitude))
                LabeledRow("Longitude", String(format: "%.6f", loc.coordinate.longitude))
                LabeledRow("Accuracy", String(format: "±%.1f m", loc.horizontalAccuracy))
            } else {
                Text("Waiting for fix…").foregroundStyle(.secondary)
            }
            if let err = model.location.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Depth / LiDAR

    private var depthCard: some View {
        Card(title: "Depth (LiDAR)", status: depthStatus) {
            LabeledRow("Supported", model.depth.isSupported ? "yes" : "no")
            LabeledRow("Nearest ahead", model.depth.nearestMeters < 0
                ? "—"
                : String(format: "%.2f m", model.depth.nearestMeters))
            LabeledRow("Obstacle", model.depth.obstacleAhead
                ? "WITHIN \(format(model.depth.thresholdMeters)) m"
                : "clear")
            if let err = model.depth.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if model.depth.isRunning {
                Button("Stop depth") { model.depth.stop() }.buttonStyle(.bordered)
            } else {
                Button("Start depth") { model.depth.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.depth.isSupported)
            }
        }
    }

    // MARK: - Motion

    private var motionCard: some View {
        Card(title: "Motion (50 Hz target)", status: motionStatus) {
            LabeledRow("Accel available", model.motion.accelAvailable ? "yes" : "no")
            LabeledRow("Gyro available", model.motion.gyroAvailable ? "yes" : "no")
            LabeledRow("Achieved rate", String(format: "%.1f Hz", model.motion.accelRateHz))
            LabeledRow("Accel samples", "\(model.motion.accelSamples)")
            HStack {
                Button(model.motion.isRunning ? "Restart" : "Start") {
                    model.motion.stop()
                    model.motion.start()
                }
                .buttonStyle(.borderedProminent)
                Button("Stop") { model.motion.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!model.motion.isRunning)
            }
        }
    }

    // MARK: - Status logic

    private var linkStatus: CardStatus {
        guard model.transmitting else { return .pending }
        return model.link.connectionState == "ready" ? .pass : .pending
    }

    private var headingStatus: CardStatus {
        switch model.location.authorization {
        case .notDetermined: return .pending
        case .denied, .restricted: return .fail
        default: return model.location.trueHeading >= 0 ? .pass : .pending
        }
    }

    private var gpsStatus: CardStatus {
        guard let loc = model.location.location else { return .pending }
        if loc.horizontalAccuracy < 0 { return .fail }
        return loc.horizontalAccuracy < 50 ? .pass : .pending
    }

    private var depthStatus: CardStatus {
        guard model.depth.isSupported else { return .fail }
        if !model.depth.isRunning { return .pending }
        return model.depth.nearestMeters > 0 ? .pass : .pending
    }

    private var motionStatus: CardStatus {
        guard model.motion.accelAvailable, model.motion.gyroAvailable else { return .fail }
        if model.motion.accelSamples == 0 { return .pending }
        return model.motion.accelRateHz >= 30 ? .pass : .pending
    }

    // MARK: - Formatting

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func authText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not requested"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when in use"
        @unknown default: return "unknown"
        }
    }
}

#Preview {
    ControlPanelView()
}
