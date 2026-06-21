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

    /// Voice layer: Deepgram Voice Agent for speech, with a Deepgram-managed `gpt-4o-mini` think
    /// stage. Claude runs separately in the on-device draft-and-verify and vision path (`claude`), not
    /// inside this socket. Off the belt's safety path; see `docs/14`.
    let voice = VoiceModel()

    /// On-device Claude tier for the spoken layer: draft a line, verify it against the structured
    /// scene, read a camera frame. Off the safety path, additive only, allowed to be slow or to fail.
    /// See `AI-USAGE-AUDIT-AND-EXPANSION.md`.
    let claude = ClaudeClient()

    /// Where the ESP32 is listening. Editable from the control panel.
    var espHost: String = "192.168.4.1"
    var espPort: UInt16 = 9999
    /// Belt transport: false = local UDP (the default, original plan), true = hosted WS relay
    /// (the internet fallback). `relayURL` is the phone's `/send` role on the deployed relay.
    var beltUseCloud = false
    var relayURL = WebSocketBeltTransport.defaultRelayURL

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

    /// Final-approach anchors (the last-50-feet wedge). Holds the decoded coded-sticker sightings while
    /// an approach is active. The guidance that turns a sighting into a beacon is deferred until blind
    /// co-design (Phase 0); this is the detection foundation. See `ios/LAST-50-FEET-SCOPING.md`.
    let anchors = AnchorStore()

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

    private var transmitter: (any BeltTransport)?
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

    /// Walk-to-calibrate state for the compass mount offset. Fed each live tick from GPS course and the
    /// compass; until it locks, the live walk withholds turn cues so the demo never opens on a
    /// few-degrees-off heading. See `HeadingCalibrator`.
    private var calibrator = HeadingCalibrator()
    /// True once the calibration walk has locked the mount offset; live turn cues wait on it.
    var isHeadingCalibrated: Bool { calibrator.isLocked }
    /// 0...1 toward a calibration lock, for the "walk forward" prompt's progress.
    var calibrationProgress: Double { calibrator.progress }

    private var cueSinks: [CueSink] { [audio] }

    init() {
        // The person tier shares the LiDAR ARSession: one frame feeds both depth and YOLO. Wiring
        // the sink here is all it takes; the decide loop already ranks a person over an obstacle.
        depth.attachVision(sink: vision, store: detections, interference: interference, anchors: anchors)
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
        // Warm the TLS connection to Anthropic once at launch so the first describe or vision read on
        // stage skips the handshake. Fire-and-forget; off the safety path; a no-op without a key.
        Task { await claude.prewarm() }
    }

    // MARK: - Link control

    func startLink() {
        guard !transmitting else { return }
        let report: @Sendable (LinkReport) -> Void = { [weak self] report in
            Task { @MainActor in self?.link = report }
        }
        let tx: any BeltTransport = beltUseCloud
            ? WebSocketBeltTransport(urlString: relayURL, report: report)
            : LC2Transmitter(host: espHost, port: espPort, report: report)
        transmitter = tx
        Task { await tx.start() }
        transmitting = true
        let dest = beltUseCloud ? relayURL : "\(espHost):\(espPort)"
        log.info("link started to \(dest, privacy: .public)")
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
        // Also satisfy the live-walk calibrator, so Live mode is not stuck "Calibrating" when a GPS
        // walk is not possible (indoors, on the bench). Trusts the compass as forward (offset 0); a
        // walking relock is still better outdoors where it can capture the magnetic bias too.
        calibrator.lockManually()
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
        calibrator.reset()   // each walk recalibrates the mount offset from a fresh few steps
        mode = .live
    }

    /// Restart the heading calibration walk: the wearer takes a few steps and the mount offset relocks.
    /// Wired to the Calibrate control so that button now does real work for the live walk.
    func recalibrateHeading() {
        calibrator.reset()
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

    /// Whether the on-device Claude tier has a key, for gating the manual demo buttons in the UI. Sync
    /// (reads `Secrets`), unlike the actor's async `isConfigured`, so a view can check it directly.
    var claudeConfigured: Bool { Secrets.anthropicAPIKey != nil }

    /// The last line a manual HUD button produced (read sign / what's around me), shown in the demo so
    /// the room can see the Claude tier answer without the mic.
    private(set) var lastDemoLine = ""

    /// Run a spoken command from a manual HUD button and surface its line. Same path the voice agent
    /// drives, so the demo shows the Claude tier with or without the mic.
    func runDemoCommand(_ command: VoiceCommand) async {
        lastDemoLine = await handleVoice(command)
    }

    /// Run a spoken command and return the line the agent should speak. Off the belt's safety path,
    /// so it is allowed to be slow and to fail without affecting navigation or the LiDAR reflex.
    func handleVoice(_ command: VoiceCommand) async -> String {
        switch command {
        case .setDestination(let place): return await setSpokenDestination(place)
        case .routeStatus: return spokenRouteStatus()
        case .nextTurn: return spokenNextTurn()
        case .tripSummary: return spokenTripSummary()
        case .whereAmI: return await spokenLocation()
        case .describeSurroundings:
            // Tier 2 (judgment): Claude reads the scene snapshot, but only when there is something
            // worth describing, and a local guard plus a grounded fallback keep it honest and fast.
            return await describeScene()
        case .checkPath:
            // Tier 0 (instant, on-device): the collision-relevant query. `ObstacleAvoidance` already
            // computes the safe open side from LiDAR; Claude would only add latency and risk here.
            return spokenPathCheck()
        case .readSign:
            return await readSign()
        case .locateEntrance:
            return await locateEntrance()
        case .recalibrate:
            return calibrate() ? "Recalibrated. Face forward and start walking." : "Hold still, then try again."
        case .connectBelt:
            guard !transmitting else { return "The belt is already connected." }
            startLink()
            return "Connecting to the belt."
        case .disconnectBelt:
            guard transmitting else { return "The belt is not connected." }
            stopLink()
            return "Disconnected from the belt."
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

    /// A natural heads-up about the next turn, in feet: "You'll make a left turn in about 100 feet."
    /// Reads the same turn cue the belt follows, so the spoken heads-up matches the tap.
    private func spokenNextTurn() -> String {
        guard !route.maneuvers.isEmpty, route.path.count >= 2 else {
            return "No route is set. Tell me where you want to go and I'll guide you."
        }
        let feet = Self.feet(fromMeters: route.distanceToNext)
        guard let cue = route.currentCue else {
            return route.distanceToNext > 0
                ? "Keep going straight. The next turn is about \(Self.roundedFeet(feet)) feet ahead."
                : "Keep going straight."
        }
        switch cue.event {
        case .arrived:
            return "You're arriving at your destination."
        case .turnAround:
            return "Make a U-turn when it's safe."
        case .forward, .idle:
            return route.distanceToNext > 0
                ? "Keep going straight for about \(Self.roundedFeet(feet)) feet."
                : "Keep going straight."
        case .turnSlight:
            return turnPhrase(direction: "a slight \(cue.mask.contains(.right) ? "right" : "left")", feet: feet)
        case .turnNow:
            return turnPhrase(direction: "a \(cue.mask.contains(.right) ? "right" : "left") turn", feet: feet)
        default:
            return turnPhrase(direction: "a turn", feet: feet)
        }
    }

    private func turnPhrase(direction: String, feet: Double) -> String {
        guard feet > 0 else { return "Make \(direction) now." }
        if feet < 25 { return "Make \(direction) just ahead." }
        return "You'll make \(direction) in about \(Self.roundedFeet(feet)) feet."
    }

    /// How far is left to the destination and a rough walking time, in feet or miles.
    private func spokenTripSummary() -> String {
        guard route.remaining >= 0, route.path.count >= 2 else {
            return "No route is set right now."
        }
        let meters = route.remaining
        if meters < 5 { return "You've arrived at your destination." }
        let seconds = RouteMath.walkingETASeconds(forDistance: meters)
        let minutes = max(1, Int((seconds / 60).rounded()))
        let distance: String
        let feet = Self.feet(fromMeters: meters)
        if feet >= 528 {                                   // a tenth of a mile or more reads in miles
            distance = String(format: "about %.1f miles", meters / 1609.34)
        } else {
            distance = "about \(Self.roundedFeet(feet)) feet"
        }
        return "You're \(distance) from your destination, around \(minutes) minute\(minutes == 1 ? "" : "s") away."
    }

    /// Meters to feet, for the spoken US-unit heads-ups.
    static func feet(fromMeters meters: Double) -> Double { meters * 3.28084 }

    /// Round feet to a friendly spoken number: nearest 10 up close, coarser farther out.
    static func roundedFeet(_ feet: Double) -> Int {
        guard feet > 0 else { return 0 }
        if feet < 100 { return max(10, Int((feet / 10).rounded()) * 10) }
        if feet < 1000 { return Int((feet / 50).rounded()) * 50 }
        return Int((feet / 100).rounded()) * 100
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
        return "Caution, \(Self.spokenObject(for: hazard)) \(distance) \(side)."
    }

    /// Name what is ahead for the spoken tier: a person only when the detector saw one, the object
    /// class when it knows it ("a backpack", "an umbrella"), or a neutral fallback otherwise.
    static func spokenObject(for hazard: Hazard) -> String {
        if hazard.isPerson { return "a person" }
        guard let label = hazard.label, !label.isEmpty else { return "something" }
        let vowel = "aeiou".contains(label.lowercased().first ?? " ")
        return "\(vowel ? "an" : "a") \(label)"
    }

    /// A descriptive read of the path for the voice agent. It fuses what the camera sees (the object or
    /// person, its side) with what the LiDAR says about the three bands, and runs the same
    /// `ObstacleAvoidance` geometry the belt uses to find which side has more room. It describes the
    /// situation and which side looks more open; it does not tell the wearer to step or stop. The
    /// wearer, their cane, and their own judgment make that call. This is deliberate: a phone-LiDAR
    /// read is advisory context (it cannot see curbs, drop-offs, stairs, head height, or glass), so it
    /// informs and never commands. Additive only; it never changes the belt cue (see `docs/12` §4).
    private func spokenPathCheck() -> String {
        guard depth.isRunning else {
            return "I can't watch the path right now. Turn the camera on so I can check for obstacles."
        }
        let bands = depth.bands
        let directive = ObstacleAvoidance.decide(left: bands.left, center: bands.center, right: bands.right,
                                                 threshold: depth.thresholdMeters,
                                                 near: CitrusSquadConfig.dangerNearMeters)
        // Prefer the camera hazard (it knows what the thing is); fall back to the raw LiDAR obstacle.
        let hazard = vision.currentHazard ?? depth.currentHazard
        let what = hazard.map { Self.spokenObject(for: $0) } ?? "something"
        let whereText = hazard.map { Self.sideWord(for: $0.mask) }

        switch directive {
        case .stop(let meters):
            // Describe the box-in; the wearer decides to stop or turn. No imperative, and a coarse
            // proximity band rather than a precise foot-count, since phone LiDAR is advisory context,
            // not a precise authority on a safety obstacle.
            return "Caution, \(what) is \(Self.spokenProximity(fromMeters: meters)), and both sides are tight."
        case .steer(let openMask, let meters):
            let open = openMask.contains(.left) ? "left" : "right"
            let place = whereText.map { " \($0)" } ?? " ahead"
            // Name what is there and state where the room is as spatial fact, not advice. The wearer,
            // their cane, and their judgment decide how to move.
            return "Heads up, \(what)\(place), \(Self.spokenProximity(fromMeters: meters)). There's more room on your \(open)."
        case .clear:
            // LiDAR sees no blockage in front, but the camera may still flag a person or object so the
            // agent can give a soft heads-up before it becomes a real obstacle.
            if let hazard, hazard.distanceMeters > 0 {
                let place = whereText.map { " \($0)" } ?? " ahead"
                return "\(Self.firstCapitalized(what))\(place), \(Self.spokenProximity(fromMeters: hazard.distanceMeters)), and the way ahead looks open."
            }
            return "The way ahead looks clear."
        }
    }

    /// A spoken distance in feet from meters, like "about 8 feet". For route distances, which are real
    /// map measurements the wearer can trust at face value.
    static func spokenFeet(fromMeters meters: Double) -> String {
        "about \(roundedFeet(feet(fromMeters: meters))) feet"
    }

    /// A coarse proximity band for an obstacle, not a precise number. Phone LiDAR is advisory context
    /// (it cannot see curbs, drop-offs, stairs, or glass), so an obstacle read is spoken as "close" or
    /// "a few steps away" rather than a foot-count that would read as precise authority the cane owns.
    static func spokenProximity(fromMeters meters: Double) -> String {
        guard meters > 0 else { return "close" }
        if meters <= 1.0 { return "very close" }
        if meters <= 2.0 { return "close" }
        if meters <= 3.5 { return "a few steps away" }
        return "farther off"
    }

    /// Which side a hazard mask sits on, phrased for speech.
    static func sideWord(for mask: QuadrantMask) -> String {
        if mask.contains(.left) { return "on your left" }
        if mask.contains(.right) { return "on your right" }
        return "straight ahead"
    }

    /// Capitalize just the first letter, so "a person" reads as "A person" at the start of a sentence.
    static func firstCapitalized(_ text: String) -> String {
        text.isEmpty ? text : text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Claude reasoning tier (Tier 2/3, off the safety path)
    //
    // Latency tiers, lowest first. Deepgram is the voice for all of them; Claude is reached only where
    // judgment (Tier 2) or vision (Tier 3) earns its latency. Everything else answers instantly from
    // on-device state (Tier 0) or a small geocode/route call (Tier 1) and never touches this section.
    // See `ios/VOICE-AI-PIPELINE.md`.

    /// Tier 2 (judgment): describe the scene. Three gates keep it fast and honest. First, if there is
    /// nothing notable in range, the grounded "clear" line is already the whole answer, so Claude is
    /// skipped entirely. Otherwise one fast-model call drafts a line over the structured snapshot under
    /// a tight voice timeout. Then a local guard (no second API call) rejects any line that claims a
    /// clear path the LiDAR contradicts. Any miss falls back to the sensor-grounded string.
    private func describeScene() async -> String {
        let grounded = spokenSurroundings()
        let snapshot = perceptionSnapshot()
        guard snapshot.isInformative, await claude.isConfigured else { return grounded }
        let line = await claude.draftLine(
            systemPrompt: Self.reasoningContract,
            snapshotXML: snapshot.xmlForClaude(),
            instruction: "In one short spoken sentence, describe what is ahead for a walker, " +
                "prioritizing anything close or in the path.",
            timeout: CitrusSquadConfig.claudeVoiceTimeoutSeconds)
        guard let line, SpokenLineGuard.isConsistent(line, with: snapshot) else { return grounded }
        return line
    }

    /// Tier 3 (vision): read a sign, label, or printed text the wearer points the camera at. This is
    /// where Claude genuinely helps a blind traveler (reading the world's text is a top community need),
    /// so it is built to be honest about it. The documented failure is the camera aimed blind plus a
    /// model that guesses; `guidedRead` coaches the aim and hedges the read instead.
    private func readSign() async -> String {
        await guidedRead(
            instruction: "Read any sign, label, number, or printed text in this frame. Report only what " +
                "is actually readable.",
            cameraOff: "I can't see anything right now. Turn the camera on and point it at the text.")
    }

    /// Tier 3 (vision): find a building entrance or door and say roughly which way it is. Coarse
    /// direction only and never a distance, because distance is exactly what vision models get wrong,
    /// and a confident wrong distance walks a blind wearer into something. Informational, never a cue.
    private func locateEntrance() async -> String {
        await guidedRead(
            instruction: "Look for a building entrance or door. If you clearly see one, say only which " +
                "coarse direction it is (ahead, to your left, or to your right). Do not state a distance. " +
                "If you do not clearly see an entrance, say so.",
            cameraOff: "I can't see anything right now. Turn the camera on and point it where you want me to look.")
    }

    /// The shared honest-read path. Grab one frame, get a structured read, and turn it into a spoken
    /// line that coaches the aim when the frame is no good and hedges when the read is uncertain or
    /// high-stakes. The "re-aim loop" is the wearer hearing the cue and asking again, which fits the
    /// one-answer-per-turn voice model and never fakes an interim. Off the safety path, informational.
    private func guidedRead(instruction: String, cameraOff: String) async -> String {
        guard await claude.isConfigured else { return "Reading isn't set up right now." }
        guard depth.isRunning, let jpeg = depth.grabFrameJPEG() else { return cameraOff }
        guard let read = await claude.read(systemPrompt: Self.readContract, instruction: instruction,
                                           imageJPEG: jpeg,
                                           timeout: CitrusSquadConfig.claudeVisionTimeoutSeconds) else {
            return "I couldn't read that. Hold steady and try again."
        }
        return Self.composeRead(read)
    }

    /// Turn a structured read into the spoken line, applying the honesty rules from the research:
    /// coach the aim when the frame was no good, and add a verification hedge on an uncertain or
    /// high-stakes read so a confident wrong answer never goes unchallenged to someone who cannot see
    /// to catch it.
    static func composeRead(_ read: VisionRead) -> String {
        let hint = read.aimHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard read.legible else {
            // Not readable: the aim cue is the answer. The wearer re-aims and asks again.
            let line = read.spokenLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if hint.isEmpty {
                return line.isEmpty ? "I can't make it out. Move closer or into better light, then ask again." : line
            }
            let lead = line.isEmpty ? "I can't quite read it." : line
            return "\(lead) \(firstCapitalized(hint))."
        }
        // Strip any distance the model stated against the contract before a word is spoken.
        let line = SpokenLineGuard.withoutVisionDistance(
            read.spokenLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return "I couldn't read that. Hold steady and try again." }

        // Normalize confidence toward doubt: anything that isn't clearly "high" is treated as less sure.
        let confident = read.confidence.lowercased() == "high"

        // A high-stakes read is ALWAYS hedged, even when the model is sure. A confident, fluent, wrong
        // read of a med name or a door number is the exact case a blind user cannot catch, so the
        // model's own confidence is not allowed to suppress the nudge; it only softens the wording.
        if read.highStakes {
            return confident
                ? line + " Worth double-checking, since this matters."
                : line + " I'm not fully sure I read that right, so double-check it with someone you trust before you rely on it."
        }
        if !confident {
            return line + " I'm not certain, though. Move closer or into better light and ask again to be sure."
        }
        return line
    }

    /// The rules for an honest camera read. Every line here is a guard against the documented ways
    /// vision models fail a blind user: guessing text, inventing a distance, and sounding certain when
    /// they are not. The wearer aimed this frame without being able to see it, so the model's other job
    /// is to coach the aim rather than answer a bad frame.
    static let readContract = """
    You are the eyes of a blind person, given one photo from a chest-mounted phone camera they aimed \
    without being able to see it. Answer what they asked and be honest about what you can and cannot \
    see.
    - Report only what you can actually make out. Never guess a letter, number, word, object, or \
    direction. If the thing is cut off, blurry, glared, too far, or out of frame, treat it as not \
    readable.
    - If you cannot answer well, set legible to false and put one short spoken re-aim cue in aimHint \
    ("tilt up", "move closer", "too dark, find more light", "pan left"). Otherwise set legible to true \
    and leave aimHint empty.
    - spokenLine is one short sentence a blind listener hears: the text or answer when you can read it, \
    or a brief note that you cannot yet.
    - For directions, give only a coarse side (ahead, left, right). Never state a distance in feet or \
    meters; you cannot judge distance reliably and a wrong number is dangerous.
    - Set highStakes to true when a misread would cause harm: medication, dosage, money or \
    denominations, an address, a room or door number, a name, an expiry date.
    - confidence is high only when the read is clear and unambiguous, medium when mostly clear, low \
    when uncertain.
    Keep every field terse. This is informational only, never a navigation or safety instruction.
    """

    /// The scene Claude reasons over, assembled from the LiDAR bands, the current fused hazard, and the
    /// route. Read on the main actor where all three already live.
    private func perceptionSnapshot() -> PerceptionSnapshot {
        // Bin every CV detection into a band using the same side convention the belt uses, and pair it
        // with its LiDAR-fused depth, so Claude sees the whole scene (what is in each band and how
        // close) rather than just the one nearest hazard.
        let scene = depth.sceneDetections.map { detection -> PerceptionSnapshot.SceneObject in
            let mask = PersonFusion.quadrant(horizontalNorm: detection.horizontalNorm)
            let band: PerceptionSnapshot.BandSide =
                mask.contains(.left) ? .left : (mask.contains(.right) ? .right : .center)
            let distance = detection.depthMedianMeters ?? detection.depthMinMeters ?? -1
            return PerceptionSnapshot.SceneObject(
                label: detection.label, distanceMeters: distance, band: band,
                tentative: detection.confidence < CitrusSquadConfig.visionTentativeConfidence)
        }
        return PerceptionSnapshot.make(bands: depth.bands, sceneObjects: scene, hazard: currentHazard(),
                                       route: routeContext(), cameraRunning: depth.isRunning)
    }

    /// The route picture for the snapshot, read from `RouteEngine`'s published state. Nil when no
    /// route is loaded, so the model never invents navigation context.
    private func routeContext() -> PerceptionSnapshot.RouteContext? {
        guard !route.maneuvers.isEmpty, route.path.count >= 2 else { return nil }
        let turn: String
        switch route.currentCue?.event {
        case .arrived: turn = "arriving"
        case .turnAround: turn = "u-turn"
        case .turnNow, .turnSlight:
            turn = (route.currentCue?.mask.contains(.right) ?? false) ? "right" : "left"
        default: turn = "straight"
        }
        return PerceptionSnapshot.RouteContext(nextTurn: turn,
                                               distanceToNextMeters: route.distanceToNext,
                                               remainingMeters: route.remaining, onRoute: true)
    }

    /// The frozen rules the describe drafter obeys. Frozen so it can be prompt-cached, and load-bearing
    /// for safety: it is what stops Claude from claiming a clear path the LiDAR did not confirm and
    /// teaches it to read the fused CV-plus-LiDAR scene. Mirrors
    /// `PERCEPTION-AVOIDANCE-HANDOFF.md` §"The reasoning contract."
    static let reasoningContract = """
    You write one short spoken line describing the scene for a blind walker wearing a haptic navigation \
    belt. You are given a structured snapshot in XML, not an image.

    How to read it:
    - The scene has three bands: left, center, right. A band may carry nearest_m, the closest distance \
    the LiDAR measured in that third, and a list of objects the camera recognised, each with its own \
    distance_m and sometimes tentative="true".
    - A band whose nearest_m is small but lists no object means something is there the camera could not \
    name: call it "something" on that side, do not guess what it is.
    - A tentative object is an uncertain detection: hedge it ("there may be...") rather than stating it \
    as fact.
    - The distances are real sensor measurements, so you may use them, but say them plainly and \
    roughly ("a couple of steps ahead", "right in front of you"), never as exact figures.

    Rules:
    - Describe only what the snapshot supports. Never claim a side is clear unless its nearest_m says \
    so, and never name an object the snapshot does not list.
    - Lead with whatever is closest or in the path. One calm sentence, meant to be heard, not read. No \
    preamble, no lists.
    - Describe the scene; do not tell the walker which way to move or whether to go. The walker and \
    their cane decide that.
    - When confidence is low, say the scene is unclear rather than inventing detail.
    """

    // MARK: - Final approach (last-50-feet wedge)

    /// Diagnostics: when on, the anchor scan runs without a target, so the Anchors card shows every
    /// coded sticker the camera decodes. This is how the detection layer is verified on device before
    /// the approach flow and the beacon exist.
    private(set) var anchorScanDiagnostic = false

    /// Start scanning for the printed anchor that labels a destination, e.g. "room-214". Records the
    /// target so the store can track how steadily it decodes. This is the seam the future, co-designed
    /// beacon flow will call; it is intentionally not yet wired to any UI or voice surface, because the
    /// guidance grammar is deferred to Phase 0 blind co-design. See `ios/LAST-50-FEET-SCOPING.md`.
    func startApproach(to label: String) {
        anchors.startApproach(to: label)
        refreshAnchorScanning()
    }

    /// Stop the approach scan and clear the target.
    func stopApproach() {
        anchors.stopApproach()
        refreshAnchorScanning()
    }

    /// Toggle the diagnostic "show me every marker" scan. Stale sightings are cleared by the decide
    /// loop once the scan is no longer active, so this just flips the gate.
    func toggleAnchorScanDiagnostic() {
        anchorScanDiagnostic.toggle()
        refreshAnchorScanning()
    }

    /// The barcode branch scans when either a real approach or the diagnostic scan is active.
    private func refreshAnchorScanning() {
        depth.anchorScanning = anchorScanDiagnostic || anchors.isApproaching
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
        // Reads the live system state, which moves even when no soak is recording. This one gate sheds
        // both the YOLO person tier and the final-approach anchor scan (both check `visionEnabled`), so
        // under heat the app falls back to the deterministic LiDAR reflex with no camera load.
        depth.visionEnabled = ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue

        // Hand the early-warning tracker the live turn rate so it can tell a centered obstacle from
        // the wearer panning the camera. When the camera tier is dropped (thermal), clear any held
        // flags so a stale heads-up cannot stick after detection stops.
        depth.latestYawRate = motion.yawRateRadPerSecond
        if !depth.visionEnabled { interference.clear() }

        // The anchor scan rides the same thermal gate. When it is shed (heat) or inactive, the delegate
        // stops calling AnchorStore.update, so clear any held sighting here, or a lost marker would
        // freeze on its last value and read as steady progress. While scanning, the delegate self-clears
        // each frame, so this never fights a live read.
        if !(depth.visionEnabled && depth.anchorScanning), !anchors.sightings.isEmpty {
            anchors.update([])
        }

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
                                  source: .hazard,
                                  label: person.label)
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
        // Let the narration defer to the voice agent when it has the floor, so the two spoken channels
        // do not collide; an urgent hazard still speaks through (decided inside the sink).
        audio.voiceActive = voice.isEngaged
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
            // Bench is the operator's heading-to-cue diagnostic (the Nav bench slider sets the target
            // bearing). It refreshes that card's cue read-out but does NOT drive the belt: with no
            // destination loaded there is nothing to navigate to, so the belt stays quiet rather than
            // steering toward a placeholder bearing. Load a route and Run sim or Walk GPS to navigate.
            // The hazard tiers still fire without a route, so obstacle avoidance keeps working.
            guard location.trueHeading >= 0 else { return nil }
            route.update(phoneHeading: location.trueHeading)
            return nil
        case .simulate:
            guard let (point, heading) = simulator.step(dt: 0.1) else { return nil }
            // The simulator's heading is already body-forward, so do not apply compass calibration.
            route.updateRoute(location: point, phoneHeading: heading, applyCalibration: false)
            return route.currentCue
        case .live:
            // Field walk: follow the route from the real GPS fix, steering off the resolved body
            // heading (GPS course while moving, accuracy-gated compass when stopped). resolveLiveHeading
            // also feeds the calibration walk, so call it every tick even before we are calibrated.
            // Until the mount offset locks, withhold the turn cue so the belt never opens on a
            // few-degrees-off heading; the wearer just walks a few steps and it engages.
            let heading = resolveLiveHeading()
            guard let fix = liveGeoPoint, isHeadingCalibrated, let heading else { return nil }
            route.updateRoute(location: fix, phoneHeading: heading, applyCalibration: false)
            return route.currentCue
        }
    }

    /// Body-forward true-north heading for the live walk, from `HeadingResolver`, with a short hold so
    /// a momentary speed dip between steps does not drop the cue. Returns nil only when there is no
    /// trustworthy heading and none was held.
    private func resolveLiveHeading() -> Double? {
        // Feed the calibration walk first, then steer with whatever mount offset it has locked (zero
        // until then). Course while moving ignores the offset; the compass fallback uses it.
        calibrator.ingest(course: location.course, courseAccuracy: location.courseAccuracy,
                          speed: location.speed, trueHeading: location.trueHeading,
                          headingAccuracy: location.headingAccuracy)
        if let resolved = HeadingResolver.resolve(
            course: location.course, courseAccuracy: location.courseAccuracy, speed: location.speed,
            trueHeading: location.trueHeading, headingAccuracy: location.headingAccuracy,
            mountOffset: calibrator.mountOffset ?? 0) {
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
