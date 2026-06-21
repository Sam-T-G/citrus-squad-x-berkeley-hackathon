import Foundation
import GoogleMaps
import os

/// One place that hands the Google Maps SDK its API key. `GMSServices.provideAPIKey` is effectively
/// a once-per-process call, so this guards it: the first non-empty key wins for the life of the
/// launch, and later calls are ignored. Changing the key after the map has loaded needs an app
/// relaunch, which the diagnostics screen tells the operator.
///
/// The same key serves both the Maps SDK (rendering the map and the my-location dot, which is free)
/// and the Directions web call (the one billed path, governed in `DirectionsService`). The key is
/// entered in the app and stored in `UserDefaults`; it is never committed.
@MainActor
enum MapsBootstrap {
    private static var didProvideKey = false
    private static let log = Logger(subsystem: "com.samuelgerungan.CitrusSquad", category: "maps")

    /// True once a key has been handed to the SDK this launch. The map view reads this to decide
    /// whether to render a live `GMSMapView` or a "enter your key" placeholder.
    static var isReady: Bool { didProvideKey }

    /// Provide the key to the SDK if it has not been provided yet this launch. Safe to call more
    /// than once and from anywhere on the main actor; only the first non-empty key takes effect.
    @discardableResult
    static func provideKeyIfNeeded(_ key: String) -> Bool {
        guard !didProvideKey else { return true }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        GMSServices.provideAPIKey(trimmed)
        didProvideKey = true
        log.info("Google Maps SDK key provided")
        return true
    }
}
