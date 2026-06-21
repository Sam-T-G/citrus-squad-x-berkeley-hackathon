import Foundation
import Observation
import os

/// Top of the app. Owns the sensor services, the route engine, the simulator, and the LC2
/// transmitter, and runs the decide loop that turns everything into one cue per tick.
///
/// The loop is the single point where input meets output. Each tick it pulls a turn cue from the
/// route engine (live heading on the bench, or the simulator), pulls the highest-priority hazard
/// from every `HazardSource` (LiDAR today, Cole's CV next), arbitrates safety over direction per
/// `docs/12`, then fans the one resolved cue out to every `CueSink` (the belt, Josh's audio).
/// Add a source or a sink and nothing in here changes.
@MainActor
@Observable
final class AppModel {
    let location = LocationService()
    let motion = MotionService()
    let depth = DepthService()
    let route = RouteEngine()
    let thermal = ThermalMonitor()

    /// Where the ESP32 is listening. Editable from the control panel.
    var espHost: String = "192.168.4.1"
    var espPort: UInt16 = 9999

    /// Provisional. When on, an active LiDAR obstacle takes priority over the route cue for that
    /// heartbeat. Toggle it off to test pure route cues. See `docs/03-protocol.md` obstacle tier.
    var obstacleCuesEnabled = true

    /// Pluggable endpoints. Cole's CV is a `HazardSource`; Josh's audio is a `CueSink`. Add more
    /// here and the decide loop fans out to them with no other change.
    let vision = VisionHazardSource()
    let audio = AudioCueSink()

    /// Demo visualizer modules. `camera` runs the preview; `detections` is Cole's CV plug point.
    let camera = CameraService()
    let detections = DetectionStore()

    /// Navigation: software simulation today, live Google Maps when a key is entered.
    let simulator = RouteSimulator()
    var mode: DriveMode = .bench
    var originText = ""
    var destinationText = ""
    private(set) var routeStatus = "no route loaded"
    private(set) var resolved: ResolvedCue = .idle

    /// Google Maps API key. One key serves both the rendered map (free) and the Directions web call
    /// (the one billed path). Entered in the app, kept in UserDefaults, never committed. Setting it
    /// also hands it to the Maps SDK so the live map can load without a relaunch.
    var directionsAPIKey: String = UserDefaults.standard.string(forKey: "citrussquad.gmapsKey") ?? "" {
        didSet {
            UserDefaults.standard.set(directionsAPIKey, forKey: "citrussquad.gmapsKey")
            MapsBootstrap.provideKeyIfNeeded(directionsAPIKey)
        }
    }

    enum DriveMode: String, CaseIterable, Sendable { case bench, simulate, live }

    private(set) var link = LinkReport(connectionState: "down", packetsSent: 0, lastEvent: "—")
    private(set) var transmitting = false

    private var transmitter: LC2Transmitter?
    private var loop: Task<Void, Never>?
    private let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "app")

    /// Governs Google Directions usage: caches, coalesces, debounces, and caps live calls so the
    /// API bill cannot run away. See `DirectionsService` and the cost-control note in the README.
    private let directions = DirectionsService()
    private(set) var directionsUsage = DirectionsUsage()
    private(set) var isFetchingRoute = false

    /// Debounces the LiDAR avoidance layer across the 10 Hz decide loop. See `ObstacleAvoidance`.
    private var avoidanceFilter = AvoidanceFilter()

    private var cueSinks: [CueSink] { [audio] }

    init() {
        // The decide loop runs from launch so the UI and simulator update even before the belt is
        // linked. Belt staging simply no-ops until a transmitter exists.
        startDecideLoop()
        Task { directionsUsage = await directions.usage() }
    }

    // MARK: - Link control

    func startLink() {
        guard !transmitting else { return }
        let tx = LC2Transmitter(host: espHost, port: espPort) { [weak self] report in
            Task { @MainActor in self?.link = report }
        }
        transmitter = tx
        Task { await tx.start() }
        transmitting = true
        log.info("link started to \(self.espHost, privacy: .public):\(self.espPort)")
    }

    func stopLink() {
        if let tx = transmitter {
            Task { await tx.stop() }
        }
        transmitter = nil
        transmitting = false
    }

    // MARK: - Operator actions

    /// Capture the phone-forward to body-forward offset. See `docs/04-phone-side.md` calibration.
    @discardableResult
    func calibrate() -> Bool {
        guard location.trueHeading >= 0 else { return false }
        route.calibrate(phoneHeading: location.trueHeading)
        return true
    }

    /// Fire one known cue so we can confirm the belt reacts. This is the M0 "hello packet" check.
    func sendTestCue() {
        stageToBelt(ResolvedCue(event: .turnNow, mask: .right,
                                intensity: CitrusSquadConfig.intensityDefault, source: .turn))
    }

    // MARK: - Navigation

    /// Load the built-in L-shaped demo route. Works with no API key and no GPS.
    func loadDemoRoute() {
        loadRoute(RouteMath.demoRoute)
        routeStatus = "demo route loaded (\(RouteMath.demoRoute.count) points)"
    }

    /// Fetch a walking route from Google Maps for the typed origin and destination. The call goes
    /// through `DirectionsService`, which serves it from cache when possible and refuses to exceed
    /// the rate and budget caps, so repeated taps never run up the bill.
    func fetchRoute() {
        guard !isFetchingRoute else { return }
        guard !directionsAPIKey.isEmpty else { routeStatus = "add a Maps API key first"; return }
        guard let origin = Self.parse(originText), let destination = Self.parse(destinationText) else {
            routeStatus = "enter origin and destination as lat,lng"
            return
        }
        isFetchingRoute = true
        routeStatus = "fetching…"
        let key = directionsAPIKey
        Task {
            defer { isFetchingRoute = false }
            do {
                let waypoints = try await directions.route(from: origin, to: destination, apiKey: key)
                loadRoute(waypoints)
                routeStatus = "loaded \(waypoints.count) points"
            } catch {
                routeStatus = "\(error)"
            }
            directionsUsage = await directions.usage()
        }
    }

    /// Set the destination from a coordinate the operator tapped on the map. No geocoding is called,
    /// so this is free. When the origin is empty and there is a GPS fix, seed it from the live
    /// position so a route can be fetched in one tap.
    func setDestinationFromTap(_ point: GeoPoint) {
        destinationText = String(format: "%.6f,%.6f", point.latitude, point.longitude)
        if originText.isEmpty, let live = location.location {
            originText = String(format: "%.6f,%.6f", live.coordinate.latitude, live.coordinate.longitude)
        }
        routeStatus = "destination set — tap Fetch to route"
    }

    /// Drop the cached routes. The next fetch for a route will hit the network once.
    func clearRouteCache() {
        Task {
            await directions.clearCache()
            directionsUsage = await directions.usage()
            routeStatus = "route cache cleared"
        }
    }

    func startSimulation() {
        mode = .simulate
        simulator.reset()
        simulator.start()
    }

    /// Field-test mode: drive the turn cues off the real GPS fix and compass instead of the virtual
    /// walker. The pure-pursuit engine follows the loaded route from wherever the wearer actually is.
    /// Calibrate facing forward first so the body-relative bearing is right.
    func startLiveWalk() {
        if location.authorization == .notDetermined { location.requestPermission() }
        location.start()
        simulator.stop()
        mode = .live
    }

    /// Stop whichever drive is active (simulated or live) and return to the idle bench state.
    func stopDriving() {
        simulator.stop()
        mode = .bench
    }

    /// Kept for callers (and voice) that say "stop simulation"; same as stopping any drive.
    func stopSimulation() { stopDriving() }

    /// True while either the simulator or a live GPS walk is driving cues.
    var isDriving: Bool { simulator.isRunning || mode == .live }

    /// The wearer's position for the map and overlay: the simulated walker in `.simulate`, the live
    /// GPS fix in `.live` (and as a fallback on the bench).
    var navPosition: GeoPoint? {
        switch mode {
        case .simulate: return simulator.position
        case .live: return liveGeoPoint
        case .bench: return liveGeoPoint ?? simulator.position
        }
    }

    /// Travel heading for the map camera: the simulated course, or the live compass.
    var navHeading: Double {
        mode == .simulate ? simulator.heading : location.trueHeading
    }

    private var liveGeoPoint: GeoPoint? {
        location.location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    private func loadRoute(_ waypoints: [GeoPoint]) {
        route.loadPath(waypoints)
        simulator.load(waypoints)
    }

    private static func parse(_ text: String) -> GeoPoint? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return GeoPoint(latitude: lat, longitude: lon)
    }

    // MARK: - Decide loop

    private func startDecideLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tick() {
        // Priority stack, highest first: a person in the path (camera) preempts everything; then the
        // LiDAR obstacle-avoidance layer steers around what is ahead; navigation rides underneath.
        let turn = currentTurnCue()
        let person = vision.currentHazard
        let avoidance = obstacleCuesEnabled ? avoidanceCue() : nil

        let decided: ResolvedCue
        if let person {
            decided = ResolvedCue(event: person.event,
                                  mask: person.mask,
                                  intensity: ResolvedCue.intensity(forDistance: person.distanceMeters),
                                  source: .hazard)
        } else if let avoidance {
            decided = avoidance
        } else if let turn {
            decided = ResolvedCue(event: turn.event,
                                  mask: turn.mask,
                                  intensity: CitrusSquadConfig.intensityDefault,
                                  source: .turn)
        } else {
            decided = .idle
        }

        resolved = decided
        stageToBelt(decided)
        for sink in cueSinks { sink.emit(decided) }
    }

    /// The LiDAR obstacle-avoidance cue, or nil when the path is clear. Reads the three depth bands,
    /// routes toward the open side (or stops and reorients when boxed in), and debounces the result
    /// so the belt does not chatter. Sits above navigation and below the camera person tier.
    private func avoidanceCue() -> ResolvedCue? {
        let raw = ObstacleAvoidance.decide(left: depth.bands.left,
                                           center: depth.bands.center,
                                           right: depth.bands.right,
                                           threshold: depth.thresholdMeters,
                                           near: CitrusSquadConfig.dangerNearMeters)
        switch avoidanceFilter.update(raw) {
        case .clear:
            return nil
        case .steer(let side, let distance):
            return ResolvedCue(event: .obstacleNear, mask: side,
                               intensity: ResolvedCue.intensity(forDistance: distance), source: .hazard)
        case .stop:
            // Boxed in or too close: full-strength halt-and-reorient on the rotate motors.
            return ResolvedCue(event: .turnAround, mask: .rotate, intensity: 255, source: .hazard)
        }
    }

    /// The turn cue for the current drive mode, or nil.
    private func currentTurnCue() -> Cue? {
        switch mode {
        case .bench:
            guard location.trueHeading >= 0 else { return nil }
            route.update(phoneHeading: location.trueHeading)
            return route.currentCue
        case .simulate:
            guard let (point, heading) = simulator.step(dt: 0.1) else { return nil }
            // The simulator's heading is already body-forward, so do not apply compass calibration.
            route.updateRoute(location: point, phoneHeading: heading, applyCalibration: false)
            return route.currentCue
        case .live:
            // Field walk: follow the route from the real GPS fix and compass.
            guard let fix = liveGeoPoint, location.trueHeading >= 0 else { return nil }
            route.updateRoute(location: fix, phoneHeading: location.trueHeading)
            return route.currentCue
        }
    }

    /// Highest-priority hazard across all sources: a person first, then the nearest obstacle.
    private func currentHazard() -> Hazard? {
        var hazards: [Hazard] = []
        if obstacleCuesEnabled, let depthHazard = depth.currentHazard { hazards.append(depthHazard) }
        if let visionHazard = vision.currentHazard { hazards.append(visionHazard) }
        if let person = hazards.filter({ $0.kind == .person }).min(by: nearer) { return person }
        return hazards.min(by: nearer)
    }

    private func nearer(_ lhs: Hazard, _ rhs: Hazard) -> Bool {
        let a = lhs.distanceMeters > 0 ? lhs.distanceMeters : .greatestFiniteMagnitude
        let b = rhs.distanceMeters > 0 ? rhs.distanceMeters : .greatestFiniteMagnitude
        return a < b
    }

    private func stageToBelt(_ cue: ResolvedCue) {
        guard let tx = transmitter else { return }
        if cue.event == .idle {
            Task { await tx.clearStaged() }
        } else {
            let packet = LC2Packet(event: cue.event, mask: cue.mask, intensity: cue.intensity)
            Task { await tx.stage(packet) }
        }
    }
}
