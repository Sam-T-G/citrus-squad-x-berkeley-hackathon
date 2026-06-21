import Foundation

/// Decodes Google's encoded polyline format into coordinates. Directions returns the real path
/// geometry (every bend in the sidewalk) as an encoded string per step and one for the whole route;
/// decoding it is what lets the belt follow the drawn line instead of cutting a straight diagonal.
///
/// The algorithm is Google's documented one: signed lat/lng deltas, zig-zag encoded, 5-bit chunks,
/// scaled by 1e5. Pure and static, so it is unit-tested against a known vector.
enum Polyline {
    static func decode(_ encoded: String) -> [GeoPoint] {
        let scalars = Array(encoded.unicodeScalars)
        var index = 0
        var lat = 0
        var lng = 0
        var points: [GeoPoint] = []

        func nextValue() -> Int? {
            var shift = 0
            var result = 0
            while index < scalars.count {
                let byte = Int(scalars[index].value) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    // Zig-zag decode: low bit is the sign.
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil   // truncated chunk; stop cleanly
        }

        while index < scalars.count {
            guard let dLat = nextValue(), let dLng = nextValue() else { break }
            lat += dLat
            lng += dLng
            points.append(GeoPoint(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return points
    }
}
