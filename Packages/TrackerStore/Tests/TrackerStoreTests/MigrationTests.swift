import XCTest
import GRDB
@testable import TrackerStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await TrackerStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "trackerstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await TrackerStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await TrackerStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesRrMs() async throws {
        let store = try await TrackerStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs"])
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await TrackerStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(TrackerStoreInfo.schemaVersion, 10)
    }

    func testV10CreatesDailyHeartRateArchive() async throws {
        let store = try await TrackerStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("dailyHeartRateArchive"))

        let pk = try await store.primaryKeyColumns("dailyHeartRateArchive")
        XCTAssertEqual(pk, ["deviceId", "day", "ts"])

        let names = try await store.indexNamesForTest(table: "dailyHeartRateArchive")
        XCTAssertTrue(names.contains("idx_dailyHeartRateArchive_device_day_ts"))
    }
}
