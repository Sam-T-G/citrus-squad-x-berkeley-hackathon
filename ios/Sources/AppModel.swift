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

    /// Maps Directions API key. Entered in the app, kept in UserDefaults, never committed.
    var directionsAPIKey: String = UserDefaults.standard.string(forKey: "citrussquad.gmapsKey") ?? "" {
        didSet { UserDefaults.standard.set(directionsAPIKey, forKey: "citrussquad.gmapsKey") }
    }

    enum DriveMode: String, CaseIterable, Sendable { case bench, simulate }

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

    func stopSimulation() {
        simulator.stop()
        mode = .bench
    }

    private func loadRoute(_ waypoints: [GeoPoint]) {
        route.loadRoute(RouteMath.maneuvers(from: waypoints))
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
        let turn = currentTurnCue()
        let hazard = currentHazard()

        let decided: ResolvedCue
        if let hazard {
            decided = ResolvedCue(event: hazard.event,
                                  mask: hazard.mask,
                                  intensity: ResolvedCue.intensity(forDistance: hazard.distanceMeters),
                                  source: .hazard)
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

    /// The turn cue for the current drive mode, or nil.
    private func currentTurnCue() -> Cue? {
        switch mode {
        case .bench:
            guard location.trueHeading >= 0 else { return nil }
            route.update(phoneHeading: location.trueHeading)
            return route.currentCue
        case .simulate:
            guard let (point, heading) = simulator.step(dt: 0.1) else { return nil }
            route.updateRoute(location: point, phoneHeading: heading)
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
