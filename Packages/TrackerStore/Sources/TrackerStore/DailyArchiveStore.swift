import Foundation
import GRDB
import TrackerProtocol

public struct FineGrainPruneResult: Equatable, Sendable {
    public let hr: Int
    public let rr: Int
    public let events: Int
    public let battery: Int
    public let spo2: Int
    public let skinTemp: Int
    public let resp: Int
    public let gravity: Int
    public let rawBatches: Int

    public var decodedRows: Int {
        hr + rr + events + battery + spo2 + skinTemp + resp + gravity
    }

    public var totalRows: Int {
        decodedRows + rawBatches
    }
}

extension TrackerStore {
    public static let defaultFineGrainRetentionSeconds = 72 * 60 * 60

    /// Replace one day's archived HR curve with minute-level averages derived from samples.
    /// `day` is the display/wake day, so the timestamps may include the previous evening when a
    /// sleep view needs overnight context.
    @discardableResult
    public func replaceDailyHeartRateArchive(_ samples: [HRSample],
                                             deviceId: String,
                                             day: String) async throws -> Int {
        let buckets = Dictionary(grouping: samples.filter { $0.bpm >= 30 && $0.bpm <= 220 }) {
            $0.ts / 60
        }
        let minuteSamples = buckets.map { minute, rows -> HRSample in
            let avg = Double(rows.reduce(0) { $0 + $1.bpm }) / Double(rows.count)
            return HRSample(ts: minute * 60 + 30, bpm: Int(avg.rounded()))
        }
        .sorted { $0.ts < $1.ts }

        return try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM dailyHeartRateArchive
                WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day])

            guard !minuteSamples.isEmpty else { return 0 }
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO dailyHeartRateArchive (deviceId, day, ts, bpm)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, day, ts) DO UPDATE SET
                    bpm = excluded.bpm
                """)
            var n = 0
            for sample in minuteSamples {
                try stmt.execute(arguments: [deviceId, day, sample.ts, sample.bpm])
                n += 1
            }
            return n
        }
    }

    /// Build or refresh a day's archived HR curve directly from full-resolution HR rows.
    @discardableResult
    public func archiveMinuteHeartRate(deviceId: String,
                                       day: String,
                                       from: Int,
                                       to: Int) async throws -> Int {
        let rows: [HRSample] = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ((ts / 60) * 60 + 30) AS ts,
                       CAST(ROUND(AVG(bpm)) AS INTEGER) AS bpm
                FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ? AND bpm >= 30 AND bpm <= 220
                GROUP BY (ts / 60)
                ORDER BY ts ASC
                """, arguments: [deviceId, from, to])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
        return try await replaceDailyHeartRateArchive(rows, deviceId: deviceId, day: day)
    }

    public func dailyHeartRateArchive(deviceId: String,
                                      day: String,
                                      limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM dailyHeartRateArchive
                WHERE deviceId = ? AND day = ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, day, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    public func archivedHeartRateSamples(deviceId: String,
                                         day: String,
                                         from: Int,
                                         to: Int,
                                         limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM dailyHeartRateArchive
                WHERE deviceId = ? AND day = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, day, from, to, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    /// Delete high-volume sensor rows once their finalized daily archive exists outside these
    /// stream tables. Summary/cache tables are intentionally preserved.
    @discardableResult
    public func pruneFineGrainData(deviceId: String, olderThan cutoffTs: Int) async throws -> FineGrainPruneResult {
        try syncWrite { db in
            func delete(_ table: String) throws -> Int {
                try db.execute(sql: """
                    DELETE FROM \(table)
                    WHERE deviceId = ? AND ts < ?
                    """, arguments: [deviceId, cutoffTs])
                return db.changesCount
            }

            let hr = try delete("hrSample")
            let rr = try delete("rrInterval")
            let events = try delete("event")
            let battery = try delete("battery")
            let spo2 = try delete("spo2Sample")
            let skinTemp = try delete("skinTempSample")
            let resp = try delete("respSample")
            let gravity = try delete("gravitySample")

            try db.execute(sql: """
                DELETE FROM rawBatch
                WHERE deviceId = ? AND (endTs < ? OR capturedAt < ?)
                """, arguments: [deviceId, cutoffTs, cutoffTs])
            let rawBatches = db.changesCount

            return FineGrainPruneResult(
                hr: hr,
                rr: rr,
                events: events,
                battery: battery,
                spo2: spo2,
                skinTemp: skinTemp,
                resp: resp,
                gravity: gravity,
                rawBatches: rawBatches
            )
        }
    }
}
