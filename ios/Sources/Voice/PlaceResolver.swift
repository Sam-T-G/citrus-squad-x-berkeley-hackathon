import Foundation
import MapKit

/// Turns a spoken place name into a coordinate the router can use.
///
/// The base routing path only accepts `lat,lng` (see `AppModel.fetchRoute`), and the team
/// deliberately avoided paid Geocoding/Places. This bridges that gap for voice without a new bill.
///
/// Resolution order, most reliable first:
/// 1. Presets. A short offline table of known demo destinations. The bulletproof replay demo
///    leans on this, so a spoken "the library" always resolves with no network.
/// 2. MKLocalSearch. Apple's free local search for anything outside the table, so the feature is
///    real in the field. No extra key, no Google cost.
struct PlaceResolver: Sendable {
    struct Resolved: Sendable, Equatable {
        var name: String
        var point: GeoPoint
    }

    enum Outcome: Sendable, Equatable {
        case resolved(Resolved)
        case ambiguous([Resolved])   // caller asks the wearer to pick
        case notFound
    }

    /// Spoken-substring -> place. Keys are lowercase. Fill these with the captured demo route's
    /// real coordinates before judging so the demo never depends on the network.
    var presets: [String: Resolved]

    init(presets: [String: Resolved] = [:]) {
        self.presets = presets
    }

    func resolve(_ spoken: String, near origin: GeoPoint?) async -> Outcome {
        let query = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return .notFound }

        if let hit = presets.first(where: { query.contains($0.key) })?.value {
            return .resolved(hit)
        }
        return await searchLocally(spoken, near: origin)
    }

    private func searchLocally(_ spoken: String, near origin: GeoPoint?) async -> Outcome {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = spoken
        if let origin {
            // Bias to a walk-scale radius so "coffee shop" means the one near the wearer.
            request.region = MKCoordinateRegion(center: origin.coordinate,
                                                latitudinalMeters: 3000,
                                                longitudinalMeters: 3000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let matches = response.mapItems.prefix(6).map { item in
                Resolved(name: item.name ?? spoken,
                         point: GeoPoint(latitude: item.placemark.coordinate.latitude,
                                         longitude: item.placemark.coordinate.longitude))
            }
            // MKLocalSearch often returns the same chain several times. Collapse by name so the agent
            // does not ask "did you mean X, or X, or X?".
            var seenNames = Set<String>()
            let unique = matches.filter { seenNames.insert($0.name).inserted }
            switch unique.count {
            case 0: return .notFound
            case 1: return .resolved(unique[0])
            default: return .ambiguous(Array(unique.prefix(3)))
            }
        } catch {
            return .notFound
        }
    }
}
