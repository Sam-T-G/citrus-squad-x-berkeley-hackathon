import Testing
import Foundation
@testable import WAND

/// Counts how many times the live fetch actually ran, so the tests can prove the governor avoids
/// network calls.
private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

struct DirectionsServiceTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "wand.test.\(UUID().uuidString)")!
    }

    private func makeService(policy: DirectionsService.Policy, counter: CallCounter) -> DirectionsService {
        DirectionsService(policy: policy, defaults: isolatedDefaults()) { origin, _, _ in
            await counter.bump()
            return [GeoPoint(latitude: origin.latitude, longitude: origin.longitude)]
        }
    }

    @Test func identicalRouteHitsNetworkOnce() async throws {
        let counter = CallCounter()
        let service = makeService(policy: .init(minIntervalSeconds: 0), counter: counter)
        let a = GeoPoint(latitude: 37.1, longitude: -122.1)
        let b = GeoPoint(latitude: 37.2, longitude: -122.2)

        _ = try await service.route(from: a, to: b, apiKey: "key")
        _ = try await service.route(from: a, to: b, apiKey: "key")

        #expect(await counter.count == 1)
        #expect(await service.usage().cacheHits == 1)
    }

    @Test func sessionCapRefusesFurtherCalls() async throws {
        let counter = CallCounter()
        let service = makeService(policy: .init(minIntervalSeconds: 0, sessionCap: 2, dailyCap: 999),
                                  counter: counter)
        _ = try await service.route(from: .init(latitude: 1, longitude: 1),
                                    to: .init(latitude: 2, longitude: 2), apiKey: "key")
        _ = try await service.route(from: .init(latitude: 3, longitude: 3),
                                    to: .init(latitude: 4, longitude: 4), apiKey: "key")

        var refused = false
        do {
            _ = try await service.route(from: .init(latitude: 5, longitude: 5),
                                        to: .init(latitude: 6, longitude: 6), apiKey: "key")
        } catch {
            refused = true
        }

        #expect(refused)
        #expect(await counter.count == 2)
    }

    @Test func debounceRefusesRapidLiveCalls() async throws {
        let counter = CallCounter()
        let service = makeService(policy: .init(minIntervalSeconds: 60), counter: counter)
        _ = try await service.route(from: .init(latitude: 1, longitude: 1),
                                    to: .init(latitude: 2, longitude: 2), apiKey: "key")

        var debounced = false
        do {
            _ = try await service.route(from: .init(latitude: 9, longitude: 9),
                                        to: .init(latitude: 8, longitude: 8), apiKey: "key")
        } catch {
            debounced = true
        }

        #expect(debounced)
        #expect(await counter.count == 1)
    }

    @Test func emptyKeyNeverCalls() async throws {
        let counter = CallCounter()
        let service = makeService(policy: .init(minIntervalSeconds: 0), counter: counter)

        var threw = false
        do {
            _ = try await service.route(from: .init(latitude: 1, longitude: 1),
                                        to: .init(latitude: 2, longitude: 2), apiKey: "")
        } catch {
            threw = true
        }

        #expect(threw)
        #expect(await counter.count == 0)
    }
}
