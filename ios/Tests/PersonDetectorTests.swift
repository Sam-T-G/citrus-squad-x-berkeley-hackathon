import Testing
@testable import CitrusSquad

/// The person-cue timing discipline from `docs/12` §6: settle before firing, hold across the
/// hysteresis band, clear no sooner than the refractory floor.
struct PersonDetectorTests {
    private let cfg = GateConfig(threshold: 1.8, hysteresis: 0.3, settleFrames: 3, refractory: 1.0)

    @Test func settleRequiresThreeFrames() {
        let (a1, g1) = PersonDetector.decide(distance: 1.0, side: .left, gate: PersonGate(), now: 10.0, cfg: cfg)
        #expect(a1 == .hold && g1.consecutive == 1)
        let (a2, g2) = PersonDetector.decide(distance: 1.0, side: .left, gate: g1, now: 10.1, cfg: cfg)
        #expect(a2 == .hold && g2.consecutive == 2)
        let (a3, g3) = PersonDetector.decide(distance: 1.0, side: .left, gate: g2, now: 10.2, cfg: cfg)
        #expect(a3 == .report(side: .left, distanceMeters: 1.0))
        #expect(g3.firing)
    }

    private func firingGate() -> PersonGate {
        var g = PersonGate()
        for t in [10.0, 10.1, 10.2] {
            (_, g) = PersonDetector.decide(distance: 1.0, side: .left, gate: g, now: t, cfg: cfg)
        }
        return g
    }

    @Test func staysFiringThroughHysteresisBand() {
        let g = firingGate()
        // 2.05 m is past the 1.8 threshold but inside 1.8 + 0.3, so the cue holds and tracks distance.
        let (action, _) = PersonDetector.decide(distance: 2.05, side: .left, gate: g, now: 10.3, cfg: cfg)
        #expect(action == .report(side: .left, distanceMeters: 2.05))
    }

    @Test func holdsWithinRefractoryThenClears() {
        let g = firingGate() // fired at now = 10.2
        let (early, gEarly) = PersonDetector.decide(distance: 2.5, side: .left, gate: g, now: 10.5, cfg: cfg)
        #expect(early == .hold && gEarly.firing) // 0.3 s < refractory, cue persists
        let (late, gLate) = PersonDetector.decide(distance: 2.5, side: .left, gate: gEarly, now: 11.3, cfg: cfg)
        #expect(late == .clear && !gLate.firing) // 1.1 s >= refractory, clears once
    }

    @Test func outOfRangeNeverSettles() {
        var g = PersonGate()
        for i in 0..<5 {
            let (action, next) = PersonDetector.decide(distance: 3.0, side: .front, gate: g, now: 20.0 + Double(i), cfg: cfg)
            g = next
            #expect(action == .hold && g.consecutive == 0)
        }
    }

    @Test func losingThePersonResetsSettle() {
        var g = PersonGate()
        (_, g) = PersonDetector.decide(distance: 1.0, side: .left, gate: g, now: 10.0, cfg: cfg)
        (_, g) = PersonDetector.decide(distance: 1.0, side: .left, gate: g, now: 10.1, cfg: cfg)
        let (action, next) = PersonDetector.decide(distance: -1, side: .front, gate: g, now: 10.2, cfg: cfg)
        #expect(action == .hold && next.consecutive == 0)
    }
}
