import Testing
@testable import CitrusSquad

/// The preset path is offline and deterministic, so it is what we test. The MKLocalSearch path
/// needs the network and is verified by hand.
struct PlaceResolverTests {
    @Test func presetMatchesAsSubstringCaseInsensitively() async {
        let point = GeoPoint(latitude: 37.8719, longitude: -122.2585)
        let resolver = PlaceResolver(presets: ["library": .init(name: "Moffitt Library", point: point)])

        let outcome = await resolver.resolve("take me to the LIBRARY please", near: nil)

        #expect(outcome == .resolved(.init(name: "Moffitt Library", point: point)))
    }

    @Test func blankInputIsNotFoundWithoutTouchingTheNetwork() async {
        let resolver = PlaceResolver(presets: [:])
        #expect(await resolver.resolve("   ", near: nil) == .notFound)
    }
}
