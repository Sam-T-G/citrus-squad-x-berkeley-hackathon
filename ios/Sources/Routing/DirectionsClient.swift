import Foundation
import CoreLocation

enum DirectionsError: Error, CustomStringConvertible {
    case badURL
    case http(Int)
    case noRoute(String)

    var description: String {
        switch self {
        case .badURL: return "bad URL"
        case .http(let code): return "HTTP \(code)"
        case .noRoute(let status): return "no route (\(status))"
        }
    }
}

/// One call to the Google Maps Directions API for a walking route. Returns the route as a list of
/// waypoints (each step's start and end), which `RouteMath.maneuvers` turns into turn cues and the
/// `RouteSimulator` walks. The whole point of the replay-first demo is that this runs once at route
/// start; nothing downstream knows or cares whether the route came from here or from a cache.
///
/// The API key is supplied by the caller (entered in the app, never committed). `URLSession.shared`
/// is fine here; this is the one HTTPS call the app makes.
struct DirectionsClient {
    let apiKey: String

    func walkingRoute(from origin: GeoPoint, to destination: GeoPoint) async throws -> [GeoPoint] {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/directions/json")
        components?.queryItems = [
            URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "mode", value: "walking"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { throw DirectionsError.badURL }

        // Send the bundle id so an "iOS apps" key restriction in Google Cloud accepts this direct
        // web-service call. Without this header, that restriction would reject the request.
        var request = URLRequest(url: url)
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DirectionsError.http(-1) }
        guard http.statusCode == 200 else { throw DirectionsError.http(http.statusCode) }

        let decoded = try JSONDecoder().decode(DirectionsResponse.self, from: data)
        guard decoded.status == "OK",
              let leg = decoded.routes.first?.legs.first,
              let firstStep = leg.steps.first else {
            throw DirectionsError.noRoute(decoded.status)
        }

        var waypoints: [GeoPoint] = [firstStep.startLocation.geoPoint]
        for step in leg.steps {
            waypoints.append(step.endLocation.geoPoint)
        }
        return waypoints
    }
}

/// The subset of the Directions JSON the app needs: each step's start and end coordinate.
private struct DirectionsResponse: Decodable {
    let status: String
    let routes: [Route]

    struct Route: Decodable { let legs: [Leg] }
    struct Leg: Decodable { let steps: [Step] }

    struct Step: Decodable {
        let startLocation: LatLng
        let endLocation: LatLng

        enum CodingKeys: String, CodingKey {
            case startLocation = "start_location"
            case endLocation = "end_location"
        }
    }

    struct LatLng: Decodable {
        let lat: Double
        let lng: Double
        var geoPoint: GeoPoint { GeoPoint(latitude: lat, longitude: lng) }
    }
}
