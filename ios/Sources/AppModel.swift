import Foundation
import CoreLocation
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

    /// Voice layer (Deepgram Voice Agent + Claude). Off the belt's safety path; see `docs/14`.
    let voice = VoiceModel()

    /// Where the ESP32 is listening. Editable from the control panel.
    var espHost: String = "192.168.4.1"
    var espPort: UInt16 = 9999

    /// Provisional. When on, an active LiDAR obstacle takes priority over the route cue for that
    /// heartbeat. Toggle it off to test pure route cues. See `docs/03-protocol.md` obstacle tier.
    var obstacleCuesEnabled = true

    /// The pre-LiDAR early-warning tier (a soft Front tap for a centered, looming object). Sits below
    /// the person and LiDAR tiers, so it can never mask a real hazard. On by default; toggle off to
    /// fall back to the depth-only behavior. See `ios/PERCEPTION-EARLY-WARNING-PLAN.md`.
    var earlyWarningCuesEnabled = true

    /// Pluggable endpoints. Cole's CV is a `HazardSource`; Josh's audio is a `CueSink`. Add more
    /// here and the decide loop fans out to them with no other change.
    let vision = VisionHazardSource()
    let audio = AudioCueSink()

    /// Demo visualizer plug point: the YOLO tier fills `detections`, and the camera preview rides the
    /// shared `DepthService` ARSession (no separate capture session).
    let detections = DetectionStore()

    /// Early-warning surface: the bearing tracker raises a flag when an object holds the wearer's
    /// heading and looms before LiDAR sees it. Diagnostics only today; the demo console reads it.
    let interference = InterferenceStore()

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
    /// Resolves a spoken place name to coordinates: presets first, then free MKLocalSearch.
    private let placeResolver = PlaceResolver()
    private(set) var directionsUsage = DirectionsUsage()
    private(set) var isFetchingRoute = false

    /// Debounces the LiDAR avoidance layer across the 10 Hz decide loop. See `ObstacleAvoidance`.
    private var avoidanceFilter = AvoidanceFilter()

    /// On-device debug log of cue and avoidance transitions. Shown in the Diagnostics screen.
    let events = EventLog()
    /// Live avoidance read-outs for the Diagnostics screen: the raw decision and the debounced one.
    private(set) var avoidanceRaw = "clear"
    private(set) var avoidanceFiltered = "clear"

    /// Last body-forward heading the resolver trusted, reused for a tick or two when it briefly returns
    /// nil (ground speed dipping between steps) so the live cue does not flicker.
    private var lastBodyHeading: Double?
    /// Which source drove the live heading last tick (`course` / `compass` / `hold`), for the field
    /// readout while validating the heading fix.
    private(set) var headingSource = "—"

    private var cueSinks: [CueSink] { [audio] }

    init() {
        // The person tier shares the LiDAR ARSession: one frame feeds both depth and YOLO. Wiring
        // the sink here is all it takes; the decide loop already ranks a person over an obstacle.
        depth.attachVision(sink: vision, store: detections, interference: interference)
        // Start location so heading and GPS are live for navigation and for voice "where am I".
        if location.authorization == .notDetermined { location.requestPermission() }
        location.start()
        // The decide loop runs from launch so the UI and simulator update even before the belt is
        // linked. Belt staging simply no-ops until a transmitter exists.
        startDecideLoop()
        Task { directionsUsage = await directions.usage() }
        // Voice runs spoken commands through the same navigation methods the UI uses. Weak self so
        // the closure never keeps the app model alive.
        voice.handler = { [weak self] command in
            guard let self else { return "" }
            return await self.handleVoice(command)
        }
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

    /// Travel heading for the map camera: the simulated course, or the resolved live body heading
    /// (GPS course while moving) so the map and the belt steer off the same direction.
    var navHeading: Double {
        mode == .simulate ? simulator.heading : (lastBodyHeading ?? location.trueHeading)
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

    // MARK: - Voice

    /// Run a spoken command and return the line the agent should speak. Off the belt's safety path,
    /// so it is allowed to be slow and to fail without affecting navigation or the LiDAR reflex.
    func handleVoice(_ command: VoiceCommand) async -> String {
        switch command {
        case .setDestination(let place): return await setSpokenDestination(place)
        case .routeStatus: return spokenRouteStatus()
        case .whereAmI: return await spokenLocation()
        case .describeSurroundings: return spokenSurroundings()
        case .recalibrate:
            return calibrate() ? "Recalibrated. Face forward and start walking." : "Hold still, then try again."
        case .stop:
            stopSimulation()
            return "Stopped."
        case .unavailable:
            return "I cannot do that yet."
        }
    }

    private func setSpokenDestination(_ spoken: String) async -> String {
        let origin = location.location.map {
            GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        switch await placeResolver.resolve(spoken, near: origin) {
        case .resolved(let place):
            destinationText = String(format: "%.6f,%.6f", place.point.latitude, place.point.longitude)
            guard let origin else {
                return "I found \(place.name), but I need a GPS fix before I can guide you there."
            }
            originText = String(format: "%.6f,%.6f", origin.latitude, origin.longitude)
            // Link voice to navigation: build a real route to the resolved place and walk it off the
            // wearer's live GPS and compass, so guidance depends on where they actually are.
            await driveToResolvedPlace(origin: origin, destination: place.point)
            return "Heading to \(place.name)."
        case .ambiguous(let options):
            let names = options.map(\.name).joined(separator: ", or ")
            return "I found a few. Did you mean \(names)?"
        case .notFound:
            return "I could not find \(spoken). Say it again."
        }
    }

    /// Build a route to a voice-resolved place and walk it off the wearer's real GPS and compass.
    /// Uses Google Directions when a key is set, otherwise a direct origin-to-destination line so the
    /// belt still points the right way. Live walk means the cues depend on where the wearer actually
    /// is, not a virtual walker.
    private func driveToResolvedPlace(origin: GeoPoint, destination: GeoPoint) async {
        if !directionsAPIKey.isEmpty {
            do {
                let waypoints = try await directions.route(from: origin, to: destination, apiKey: directionsAPIKey)
                loadRoute(waypoints)
                routeStatus = "voice route: \(waypoints.count) points"
            } catch {
                loadRoute([origin, destination])
                routeStatus = "voice route (direct): \(error)"
            }
        } else {
            loadRoute([origin, destination])
            routeStatus = "voice route (direct line)"
        }
        startLiveWalk()
    }

    private func spokenRouteStatus() -> String {
        guard !route.maneuvers.isEmpty else { return "No route is loaded." }
        let remaining = max(0, route.maneuvers.count - route.activeIndex)
        if route.distanceToNext > 0 {
            return "About \(Int(route.distanceToNext.rounded())) meters to the next turn. \(remaining) turns left."
        }
        return "On route. \(remaining) turns left."
    }

    /// Reverse-geocode the current GPS fix to a spoken place. Real location context from Maps.
    private func spokenLocation() async -> String {
        guard let fix = location.location else {
            return "I don't have a location fix yet. Check that location is allowed, and try again outdoors."
        }
        let geocoder = CLGeocoder()
        if let placemark = try? await geocoder.reverseGeocodeLocation(fix).first {
            let spot = placemark.name ?? placemark.thoroughfare ?? placemark.locality
            if let spot, let city = placemark.locality, city != spot {
                return "You are near \(spot), in \(city)."
            }
            if let spot { return "You are near \(spot)." }
        }
        return String(format: "You are at latitude %.4f, longitude %.4f.",
                      fix.coordinate.latitude, fix.coordinate.longitude)
    }

    /// Cautious narration grounded in the LiDAR hazard. V3 wraps this in a Claude draft-and-verify
    /// pass per `docs/14`; until then it states only what the depth tier actually reports, so it
    /// cannot claim a clear path the sensors did not confirm.
    private func spokenSurroundings() -> String {
        guard let hazard = currentHazard() else { return "The path ahead looks clear." }
        let side = hazard.mask.contains(.right) ? "on your right"
            : hazard.mask.contains(.left) ? "on your left" : "ahead"
        let distance = hazard.distanceMeters > 0
            ? "about \(Int(hazard.distanceMeters.rounded())) meters"
            : "close"
        let what = hazard.kind == .person ? "a person" : "something"
        return "Caution, \(what) \(distance) \(side)."
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
        // Thermal degrade ladder (docs/12 §6): at .serious, drop the camera tier and lean on LiDAR.
        // Reads the live system state, which moves even when no soak is recording.
        depth.visionEnabled = ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue

        // Hand the early-warning tracker the live turn rate so it can tell a centered obstacle from
        // the wearer panning the camera. When the camera tier is dropped (thermal), clear any held
        // flags so a stale heads-up cannot stick after detection stops.
        depth.latestYawRate = motion.yawRateRadPerSecond
        if !depth.visionEnabled { interference.clear() }

        // Priority stack, highest first: a person in the path (camera) preempts everything; then the
        // LiDAR obstacle-avoidance layer steers around what is ahead; then the pre-LiDAR early-warning
        // heads-up; navigation rides underneath. Each lower tier only fires when the ones above are
        // quiet, so the soft heads-up can never delay or mask a confirmed person or obstacle cue.
        let turn = currentTurnCue()
        let person = vision.currentHazard
        let avoidance = obstacleCuesEnabled ? avoidanceCue() : nil
        let earlyWarning = earlyWarningCuesEnabled ? earlyWarningCue() : nil

        let decided: ResolvedCue
        if let person {
            decided = ResolvedCue(event: person.event,
                                  mask: person.mask,
                                  intensity: ResolvedCue.intensity(forDistance: person.distanceMeters),
                                  source: .hazard)
        } else if let avoidance {
            decided = avoidance
        } else if let earlyWarning {
            decided = earlyWarning
        } else if let turn {
            decided = ResolvedCue(event: turn.event,
                                  mask: turn.mask,
                                  intensity: CitrusSquadConfig.intensityDefault,
                                  source: .turn)
        } else {
            decided = .idle
        }

        resolved = decided
        events.log("cue",
                   "\(decided.event.label) mask=0x\(String(decided.mask.rawValue, radix: 16)) [\(decided.source.rawValue)]",
                   dedupKey: "\(decided.event.rawValue)-\(decided.mask.rawValue)-\(decided.source.rawValue)")
        stageToBelt(decided)
        for sink in cueSinks { sink.emit(decided) }
    }

    /// The LiDAR obstacle-avoidance cue, or nil when the path is clear. Reads the three depth bands,
    /// routes toward the open side (or stops and reorients when boxed in), and debounces the result
    /// so the belt does not chatter. Sits above navigation and below the camera person tier.
    private func avoidanceCue() -> ResolvedCue? {
        let bands = depth.bands
        let raw = ObstacleAvoidance.decide(left: bands.left,
                                           center: bands.center,
                                           right: bands.right,
                                           threshold: depth.thresholdMeters,
                                           near: CitrusSquadConfig.dangerNearMeters)
        let filtered = avoidanceFilter.update(raw)
        avoidanceRaw = raw.description
        avoidanceFiltered = filtered.description
        // Log on a state change, with the band values that produced it, so the bench can see exactly
        // why a stop or a steer fired.
        events.log("avoid",
                   "\(filtered.description)  (L \(Self.fmt(bands.left)) C \(Self.fmt(bands.center)) R \(Self.fmt(bands.right)), thr \(String(format: "%.1f", depth.thresholdMeters)))",
                   dedupKey: filtered.stateKey)

        switch filtered {
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

    private static func fmt(_ meters: Double) -> String {
        meters < 0 ? "—" : String(format: "%.2f", meters)
    }

    /// The soft pre-LiDAR heads-up, or nil when nothing is on a collision course. Fires whenever the
    /// bearing tracker is holding a flag (a centered, looming object). The flag already carries the
    /// settle discipline, so this needs no debounce of its own; it is gated below the person and LiDAR
    /// tiers in `tick`, so it only reaches the belt when the path is otherwise quiet.
    private func earlyWarningCue() -> ResolvedCue? {
        guard interference.active != nil else { return nil }
        return .earlyWarning
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
            // Field walk: follow the route from the real GPS fix, steering off the resolved body
            // heading (GPS course while moving, accuracy-gated compass when stopped). The resolved
            // value is already body-forward true north, so the calibration offset is bypassed.
            guard let fix = liveGeoPoint, let heading = resolveLiveHeading() else { return nil }
            route.updateRoute(location: fix, phoneHeading: heading, applyCalibration: false)
            return route.currentCue
        }
    }

    /// Body-forward true-north heading for the live walk, from `HeadingResolver`, with a short hold so
    /// a momentary speed dip between steps does not drop the cue. Returns nil only when there is no
    /// trustworthy heading and none was held.
    private func resolveLiveHeading() -> Double? {
        if let resolved = HeadingResolver.resolve(
            course: location.course, courseAccuracy: location.courseAccuracy, speed: location.speed,
            trueHeading: location.trueHeading, headingAccuracy: location.headingAccuracy) {
            lastBodyHeading = resolved.degrees
            headingSource = resolved.source.rawValue
            return resolved.degrees
        }
        if lastBodyHeading != nil { headingSource = "hold" }
        return lastBodyHeading
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
