import Foundation

/// A usage snapshot for the UI, so the operator can see exactly how many paid calls have gone out.
struct DirectionsUsage: Sendable, Equatable {
    var sessionCalls = 0
    var dailyCalls = 0
    var cacheHits = 0
    var cachedRoutes = 0
}

enum DirectionsGovernorError: Error, CustomStringConvertible {
    case emptyKey
    case debounced(retryAfterSeconds: Int)
    case sessionCapReached(Int)
    case dailyCapReached(Int)

    var description: String {
        switch self {
        case .emptyKey: return "no Maps API key"
        case .debounced(let seconds): return "slow down: wait \(seconds)s between live fetches"
        case .sessionCapReached(let cap): return "session cap reached (\(cap) calls); restart the app to reset"
        case .dailyCapReached(let cap): return "daily cap reached (\(cap) calls); resets at midnight"
        }
    }
}

/// Governs Google Directions API usage so the bill never runs away. The guards, in order of how
/// much each saves:
///
/// 1. Result cache keyed by rounded coordinates, persisted across launches. Identical routes never
///    hit the network, so the demo route is fetched at most once ever.
/// 2. In-flight coalescing. Concurrent requests for the same route share one network call.
/// 3. Debounce. A minimum interval between live calls stops double-taps and tight loops.
/// 4. Hard caps. Per-session and per-day ceilings; once hit, calls are refused, not queued.
/// 5. No automatic retries. A failure never silently re-spends; the operator re-triggers.
///
/// These are defense in depth. The authoritative backstop is server side: set a daily quota and a
/// billing budget alert in Google Cloud, and restrict the key to this app. A key with no quota is
/// what actually runs up a bill. See `ios/README.md`.
actor DirectionsService {
    struct Policy: Sendable {
        var minIntervalSeconds: Double = 5
        var sessionCap = 20
        var dailyCap = 100
        var cacheTTL: TimeInterval = 60 * 60 * 24 * 7   // a week; walking routes are stable
        var coordinateDecimals = 5                       // ~1.1 m; folds GPS float noise into a hit
    }

    typealias Fetch = @Sendable (GeoPoint, GeoPoint, String) async throws -> [GeoPoint]

    private let policy: Policy
    private let defaults: UserDefaults
    private let fetch: Fetch

    private var cache: [String: CacheEntry]
    private var inFlight: [String: Task<[GeoPoint], Error>] = [:]
    private var lastCallAt: Date?
    private var sessionCalls = 0
    private var cacheHits = 0

    init(policy: Policy = Policy(),
         defaults: UserDefaults = .standard,
         fetch: @escaping Fetch = { origin, destination, key in
             try await DirectionsClient(apiKey: key).walkingRoute(from: origin, to: destination)
         }) {
        self.policy = policy
        self.defaults = defaults
        self.fetch = fetch
        self.cache = Self.loadCache(from: defaults)
    }

    /// Return the route for a leg, from cache if possible, otherwise one governed live call.
    func route(from origin: GeoPoint, to destination: GeoPoint, apiKey: String) async throws -> [GeoPoint] {
        guard !apiKey.isEmpty else { throw DirectionsGovernorError.emptyKey }
        let key = cacheKey(origin, destination)

        // 1. Fresh cache hit: zero network, zero cost.
        if let entry = cache[key], Date().timeIntervalSince(entry.storedAt) < policy.cacheTTL {
            cacheHits += 1
            return entry.waypoints
        }

        // 2. Coalesce concurrent identical requests onto one call.
        if let existing = inFlight[key] {
            return try await existing.value
        }

        // 3. Debounce live calls.
        if let last = lastCallAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < policy.minIntervalSeconds {
                let wait = Int((policy.minIntervalSeconds - elapsed).rounded(.up))
                throw DirectionsGovernorError.debounced(retryAfterSeconds: max(1, wait))
            }
        }

        // 4. Hard caps. Refuse, do not delay.
        guard sessionCalls < policy.sessionCap else {
            throw DirectionsGovernorError.sessionCapReached(policy.sessionCap)
        }
        let today = Self.dayStamp()
        let daily = dailyCount(for: today)
        guard daily < policy.dailyCap else {
            throw DirectionsGovernorError.dailyCapReached(policy.dailyCap)
        }

        // 5. Count the attempt before awaiting, so a tight loop cannot outrun the cap, then make
        //    exactly one call with no automatic retry.
        lastCallAt = Date()
        sessionCalls += 1
        setDailyCount(daily + 1, for: today)

        let task = Task<[GeoPoint], Error> { [fetch] in
            try await fetch(origin, destination, apiKey)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let waypoints = try await task.value
        cache[key] = CacheEntry(waypoints: waypoints, storedAt: Date())
        saveCache()
        return waypoints
    }

    func usage() -> DirectionsUsage {
        DirectionsUsage(sessionCalls: sessionCalls,
                        dailyCalls: dailyCount(for: Self.dayStamp()),
                        cacheHits: cacheHits,
                        cachedRoutes: cache.count)
    }

    func clearCache() {
        cache = [:]
        saveCache()
    }

    // MARK: - Cache key

    private func cacheKey(_ a: GeoPoint, _ b: GeoPoint) -> String {
        let decimals = policy.coordinateDecimals
        func rounded(_ value: Double) -> String { String(format: "%.\(decimals)f", value) }
        return "\(rounded(a.latitude)),\(rounded(a.longitude))->\(rounded(b.latitude)),\(rounded(b.longitude))"
    }

    // MARK: - Persistence

    struct CacheEntry: Codable, Sendable {
        var waypoints: [GeoPoint]
        var storedAt: Date
    }

    private static let cacheDefaultsKey = "wand.dir.cache"
    private static let dailyCountKey = "wand.dir.dailyCount"
    private static let dailyDateKey = "wand.dir.dailyDate"

    private static func loadCache(from defaults: UserDefaults) -> [String: CacheEntry] {
        guard let data = defaults.data(forKey: cacheDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.cacheDefaultsKey)
    }

    private func dailyCount(for day: String) -> Int {
        guard defaults.string(forKey: Self.dailyDateKey) == day else { return 0 }
        return defaults.integer(forKey: Self.dailyCountKey)
    }

    private func setDailyCount(_ count: Int, for day: String) {
        defaults.set(day, forKey: Self.dailyDateKey)
        defaults.set(count, forKey: Self.dailyCountKey)
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}
