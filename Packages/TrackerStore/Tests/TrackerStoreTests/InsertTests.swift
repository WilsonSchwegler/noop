import XCTest
import TrackerProtocol
@testable import TrackerStore

final class InsertTests: XCTestCase {
    private func sampleStreams() -> Streams {
        Streams(
            hr: [HRSample(ts: 1000, bpm: 60), HRSample(ts: 1001, bpm: 61)],
            rr: [RRInterval(ts: 1000, rrMs: 800), RRInterval(ts: 1000, rrMs: 820)],
            events: [TrackerEvent(ts: 1736365593, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["foo": .int(7), "bar": .string("x")])],
            battery: [BatterySample(ts: 1736365593, soc: 25.5, mv: nil)])
    }

    func testInsertReturnsRowCounts() async throws {
        let store = try await TrackerStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: "AA:BB", name: "Strap")
        let n = try await store.insert(sampleStreams(), deviceId: "dev1")
        XCTAssertEqual(n.hr, 2)
        XCTAssertEqual(n.rr, 2)
        XCTAssertEqual(n.events, 1)
        XCTAssertEqual(n.battery, 1)
    }

    func testInsertIsIdempotentByNaturalKey() async throws {
        let store = try await TrackerStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(sampleStreams(), deviceId: "dev1")
        let second = try await store.insert(sampleStreams(), deviceId: "dev1")
        // Same natural keys → nothing new inserted the second time.
        XCTAssertEqual(second.hr, 0)
        XCTAssertEqual(second.rr, 0)
        XCTAssertEqual(second.events, 0)
        XCTAssertEqual(second.battery, 0)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 2)
        XCTAssertEqual(stats.rr, 2)
        XCTAssertEqual(stats.events, 1)
        XCTAssertEqual(stats.battery, 1)
        XCTAssertEqual(stats.spo2, 0)
        XCTAssertEqual(stats.skinTemp, 0)
        XCTAssertEqual(stats.resp, 0)
        XCTAssertEqual(stats.gravity, 0)
    }

    func testUpsertDeviceUpdatesFields() async throws {
        let store = try await TrackerStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: "AA", name: "first")
        try await store.upsertDevice(id: "dev1", mac: "BB", name: "second")
        let row = try await store.deviceRowForTest(id: "dev1")
        XCTAssertEqual(row?.mac, "BB")
        XCTAssertEqual(row?.name, "second")
    }

    func testTwoDevicesAreIndependent() async throws {
        let store = try await TrackerStore.inMemory()
        try await store.upsertDevice(id: "a", mac: nil, name: nil)
        try await store.upsertDevice(id: "b", mac: nil, name: nil)
        _ = try await store.insert(sampleStreams(), deviceId: "a")
        let nb = try await store.insert(sampleStreams(), deviceId: "b")
        XCTAssertEqual(nb.hr, 2)   // same ts/bpm but different deviceId → not a conflict
    }

    func testMergeDeviceDataMovesRowsAndDropsDuplicates() async throws {
        let store = try await TrackerStore.inMemory()
        try await store.upsertDevice(id: "stable", mac: nil, name: "stable")
        try await store.upsertDevice(id: "renamed", mac: nil, name: "renamed")
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 1000, bpm: 60), HRSample(ts: 1001, bpm: 61)]),
            deviceId: "renamed"
        )
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 1001, bpm: 61)]),
            deviceId: "stable"
        )
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-06-11", totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                        restingHr: nil, avgHrv: nil, recovery: 0.7, strain: 12, exerciseCount: nil),
        ], deviceId: "renamed")

        let changed = try await store.mergeDeviceData(from: "renamed", into: "stable")

        XCTAssertGreaterThan(changed, 0)
        let stableHR = try await store.hrSamples(deviceId: "stable", from: 0, to: 2_000, limit: 10)
        XCTAssertEqual(stableHR.map(\.ts), [1000, 1001])
        let renamedHR = try await store.hrSamples(deviceId: "renamed", from: 0, to: 2_000, limit: 10)
        XCTAssertTrue(renamedHR.isEmpty)
        let daily = try await store.dailyMetrics(deviceId: "stable", from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(daily.map(\.day), ["2026-06-11"])
        let renamedDevice = try await store.deviceRowForTest(id: "renamed")
        XCTAssertNil(renamedDevice)
    }
}
