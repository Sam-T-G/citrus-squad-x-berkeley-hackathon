import SwiftUI
import CoreLocation
import UIKit

/// The diagnostics console: one card per subsystem (link, navigation, heading, GPS, depth, motion,
/// thermal soak) for bench-testing every sensor and the belt link. The clean operator screen for
/// the demo is `ProductionView`; both share one injected `AppModel`.
struct ControlPanelView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        @Bindable var route = model.route
        @Bindable var audio = model.audio

        ScrollView {
            VStack(spacing: 16) {
                header
                linkCard(host: $model.espHost, port: $model.espPort)
                navigationCard(apiKey: $model.directionsAPIKey,
                               origin: $model.originText,
                               destination: $model.destinationText,
                               mode: $model.mode,
                               audioEnabled: $audio.isEnabled)
                navCard(bearing: $route.targetRouteBearing)
                headingCard
                gpsCard
                depthCard(obstacleEnabled: $model.obstacleCuesEnabled,
                          earlyWarningEnabled: $model.earlyWarningCuesEnabled)
                avoidanceCard
                eventLogCard
                motionCard
                soakCard
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Avoidance (live)

    private var avoidanceCard: some View {
        Card(title: "Avoidance (LiDAR)", status: model.avoidanceFiltered == "clear" ? .pending : .pass) {
            LabeledRow("Bands L / C / R", bandText)
            LabeledRow("Threshold", String(format: "%.1f m", model.depth.thresholdMeters))
            LabeledRow("Danger-near", String(format: "%.1f m", CitrusSquadConfig.dangerNearMeters))
            LabeledRow("Raw decision", model.avoidanceRaw)
            LabeledRow("Belt (debounced)", model.avoidanceFiltered)
            Text("A band reads its nearest return within threshold. Both sides blocked → stop; one side blocked → steer to the other; else steer to the roomier side.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Event log

    private var eventLogCard: some View {
        Card(title: "Event log", status: .pending) {
            HStack {
                Button("Copy") { UIPasteboard.general.string = model.events.exportText() }
                    .buttonStyle(.bordered)
                Button("Clear") { model.events.clear() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(model.events.events.count) events").font(.caption).foregroundStyle(.secondary)
            }
            if model.events.events.isEmpty {
                Text("No events yet. Start depth and move toward an obstacle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.events.events.suffix(40).reversed()) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Text(event.time).foregroundStyle(.secondary)
                        Text("[\(event.tag)]").foregroundStyle(event.tag == "avoid" ? .orange : .blue)
                        Text(event.detail)
                    }
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Citrus Squad").font(.largeTitle.bold())
            Text("Citrus Squad — phone-side control").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top)
    }

    // MARK: - Link

    private func linkCard(host: Binding<String>, port: Binding<UInt16>) -> some View {
        Card(title: "Belt link (LC2 / UDP)", status: linkStatus) {
            HStack {
                TextField("Belt host (laptop or ESP32)", text: host)
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

    // MARK: - Navigation (simulate + Maps)

    private func navigationCard(apiKey: Binding<String>,
                                origin: Binding<String>,
                                destination: Binding<String>,
                                mode: Binding<AppModel.DriveMode>,
                                audioEnabled: Binding<Bool>) -> some View {
        Card(title: "Navigation", status: navigationStatus) {
            Picker("Mode", selection: mode) {
                Text("Bench").tag(AppModel.DriveMode.bench)
                Text("Simulate").tag(AppModel.DriveMode.simulate)
                Text("Live").tag(AppModel.DriveMode.live)
            }
            .pickerStyle(.segmented)

            LabeledRow("Status", model.routeStatus)
            LabeledRow("Resolved cue", resolvedText)
            if model.mode == .simulate {
                LabeledRow("Sim segment", "\(model.simulator.segmentIndex)")
            }
            if model.isDriving {
                LabeledRow("Distance to turn", model.route.distanceToNext < 0
                    ? "—"
                    : String(format: "%.1f m", model.route.distanceToNext))
                LabeledRow("Distance left", model.route.remaining < 0
                    ? "—"
                    : String(format: "%.0f m", model.route.remaining))
            }
            if model.mode == .live, let fix = model.location.location {
                LabeledRow("GPS accuracy", String(format: "±%.0f m", fix.horizontalAccuracy))
            }

            HStack {
                Button("Load demo route") { model.loadDemoRoute() }
                    .buttonStyle(.bordered)
                if model.isDriving {
                    Button("Stop") { model.stopDriving() }.buttonStyle(.bordered)
                } else {
                    Button("Run sim") { model.startSimulation() }.buttonStyle(.borderedProminent)
                }
            }
            if !model.isDriving {
                Button("Walk (live GPS)") { model.startLiveWalk() }
                    .buttonStyle(.bordered)
                    .disabled(model.route.path.count < 2 || model.location.location == nil)
            }

            DisclosureGroup("Live Google Maps") {
                SecureField("Google Maps API key", text: apiKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("One key powers both the live map (free) and route fetches (billed, capped). Changing it after the map has loaded needs an app relaunch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("origin lat,lng", text: origin)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("destination lat,lng", text: destination)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Fetch route") { model.fetchRoute() }
                    .buttonStyle(.bordered)
                    .disabled(apiKey.wrappedValue.isEmpty || model.isFetchingRoute)

                LabeledRow("Calls this session", "\(model.directionsUsage.sessionCalls)")
                LabeledRow("Calls today", "\(model.directionsUsage.dailyCalls)")
                LabeledRow("Cache hits", "\(model.directionsUsage.cacheHits)")
                LabeledRow("Cached routes", "\(model.directionsUsage.cachedRoutes)")
                Button("Clear route cache") { model.clearRouteCache() }
                    .buttonStyle(.bordered)
            }

            Toggle("Speak cues (audio)", isOn: audioEnabled)
        }
    }

    private var navigationStatus: CardStatus {
        if model.simulator.isRunning { return .pass }
        return model.route.maneuvers.isEmpty ? .pending : .pass
    }

    private var resolvedText: String {
        let cue = model.resolved
        guard cue.event != .idle else { return "idle" }
        return "\(cue.event.label) mask=0x\(String(cue.mask.rawValue, radix: 16)) [\(cue.source.rawValue)]"
    }

    // MARK: - Heading

    private var headingCard: some View {
        Card(title: "Heading", status: headingStatus) {
            LabeledRow("Permission", authText(model.location.authorization))
            LabeledRow("True heading", "\(format(model.location.trueHeading))°")
            LabeledRow("Accuracy", "±\(format(model.location.headingAccuracy))°")
            LabeledRow("GPS course", model.location.course < 0 ? "—" : "\(format(model.location.course))°")
            LabeledRow("Speed", model.location.speed < 0 ? "—" : String(format: "%.1f m/s", model.location.speed))
            LabeledRow("Steering from", model.headingSource)
            LabeledRow("Calibration", model.isHeadingCalibrated
                ? "locked"
                : "walk to calibrate (\(Int(model.calibrationProgress * 100))%)")
            Button("Recalibrate heading") { model.recalibrateHeading() }
                .buttonStyle(.bordered)
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

    private func depthCard(obstacleEnabled: Binding<Bool>, earlyWarningEnabled: Binding<Bool>) -> some View {
        Card(title: "Depth (LiDAR)", status: depthStatus) {
            LabeledRow("Supported", model.depth.isSupported ? "yes" : "no")
            LabeledRow("Nearest ahead", model.depth.nearestMeters < 0
                ? "—"
                : String(format: "%.2f m", model.depth.nearestMeters))
            LabeledRow("Bands L / C / R", bandText)
            LabeledRow("Obstacle", model.depth.obstacleAhead
                ? "WITHIN \(format(model.depth.thresholdMeters)) m"
                : "clear")
            Toggle("Emit obstacle cue (provisional)", isOn: obstacleEnabled)
            Toggle("Early-warning heads-up (pre-LiDAR)", isOn: earlyWarningEnabled)
            LabeledRow("Early warnings", "\(model.interference.flaggedFrameCount)")
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

    // MARK: - Thermal soak

    private var soakCard: some View {
        Card(title: "Thermal soak", status: thermalStatus) {
            LabeledRow("Current", model.thermal.currentLabel)
            LabeledRow("Peak", model.thermal.peakLabel)
            LabeledRow("Elapsed", "\(model.thermal.elapsedSeconds) s")
            LabeledRow("Time in state", model.thermal.summary)
            Text("Start depth, link, and motion first, then run this while walking the loop for 10 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.thermal.isSoaking {
                Button("Stop soak") { model.thermal.stopSoak() }.buttonStyle(.bordered)
            } else {
                Button("Start soak") { model.thermal.startSoak() }.buttonStyle(.borderedProminent)
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

    private var bandText: String {
        let bands = model.depth.bands
        func fmt(_ value: Double) -> String { value < 0 ? "—" : String(format: "%.1f", value) }
        return "\(fmt(bands.left)) / \(fmt(bands.center)) / \(fmt(bands.right))"
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

    private var thermalStatus: CardStatus {
        switch model.thermal.peak {
        case .nominal, .fair: return .pass
        case .serious: return .pending
        case .critical: return .fail
        @unknown default: return .pending
        }
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
    ControlPanelView(model: AppModel())
}
