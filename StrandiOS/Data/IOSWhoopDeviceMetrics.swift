import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

struct IOSLoadGuidance: Equatable {
    var title = "Building baseline"
    var detail = "Collect more WHOOP strain history for training-load guidance."
    var acwr: Double?
    var targetLow: Double?
    var targetHigh: Double?
    var colorKey = "neutral"
}

struct IOSDeviceWorkout: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let durationMinutes: Int
    let avgHR: Int
    let maxHR: Int
    let strain: Double?
    let calories: Double?

    var title: String { "Detected workout" }
}

struct IOSMetricHRSample: Identifiable, Equatable {
    let id: Int
    let ts: Int
    let bpm: Int
}

struct IOSWhoopDeviceSnapshot: Equatable {
    var status = "Waiting for WHOOP data"
    var decodedRows = 0
    var latestSampleAt: Date?
    var strain: Double?
    var recovery: Double?
    var recoveryStatus = "Calibrating from WHOOP nights"
    var restingHR: Int?
    var hrvRMSSD: Double?
    var sleepHRVRMSSD: Double?
    var whoopSleepHours = 0.0
    var whoopSleepEfficiency = 0.0
    var whoopSleepStages: [IOSSleepStageSummary] = []
    var whoopSleepIntervals: [IOSSleepInterval] = []
    var whoopSleepStatus = "Waiting for overnight WHOOP HR"
    var sleepSpO2RawRatio: Double?
    var sleepSkinTempRaw: Double?
    var calories: Double?
    var exerciseMinutes = 0
    var steps = 0
    var stepsSource = "Estimated from WHOOP motion"
    var activityPoints = 0
    var workouts: [IOSDeviceWorkout] = []
    var todayHRSamples: [IOSMetricHRSample] = []
    var dailyHRSamples: [IOSMetricHRSample] = []
    var loadGuidance = IOSLoadGuidance()

    static let empty = IOSWhoopDeviceSnapshot()
}

enum IOSWhoopDeviceMetrics {
    static let dailyLogVersion = 11
    private static let maxLoggedSleepIntervals = 96

    static func loggedDaySnapshot(store: WhoopStore,
                                  deviceId: String,
                                  date: Date,
                                  calendar: Calendar = .current) async throws -> IOSWhoopDeviceSnapshot? {
        let selectedStartDate = calendar.startOfDay(for: date)
        let selectedEndDate = calendar.date(byAdding: .day, value: 1, to: selectedStartDate)?.addingTimeInterval(-1) ?? date
        let selectedStart = Int(selectedStartDate.timeIntervalSince1970)
        let selectedEnd = Int(selectedEndDate.timeIntervalSince1970)
        let selectedDay = dayString(selectedStartDate, calendar: calendar)
        let values = try await loggedMetrics(store: store, deviceId: deviceId, day: selectedDay)
        guard Int(values["noop.logVersion"] ?? 0) >= dailyLogVersion else { return nil }
        guard values["noop.finalized"] == 1 || values["noop.snapshotUpdatedAt"] != nil else { return nil }
        let stats = try await store.storageStats()
        let latest = try await store.latestHRSampleTs(deviceId: deviceId)
        let hr = try await store.hrSamples(deviceId: deviceId, from: selectedStart, to: selectedEnd, limit: 120_000)
        let contextHR = try await store.hrSamples(deviceId: deviceId, from: selectedStart - 12 * 3600, to: selectedEnd, limit: 160_000)
        let gravity = try await store.gravitySamples(deviceId: deviceId, from: selectedStart, to: selectedEnd, limit: 120_000)
        var snapshot = loggedSnapshot(values: values, stats: stats, latest: latest, hr: hr)
        snapshot.dailyHRSamples = contextHR.enumerated().map { index, sample in
            IOSMetricHRSample(id: index, ts: sample.ts, bpm: sample.bpm)
        }
        snapshot.activityPoints = gravity.count
        return snapshot
    }

    static func refresh(store: WhoopStore,
                        deviceId: String,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        recalculateSleep: Bool = false) async throws -> IOSWhoopDeviceSnapshot {
        let selectedStartDate = calendar.startOfDay(for: now)
        let todayStartDate = calendar.startOfDay(for: Date())
        let selectedDayIsToday = calendar.isDate(selectedStartDate, inSameDayAs: todayStartDate)
        let selectedEndOfDay = calendar.date(byAdding: .day, value: 1, to: selectedStartDate)?.addingTimeInterval(-1) ?? now
        let selectedEndDate = selectedDayIsToday ? min(now, selectedEndOfDay) : selectedEndOfDay
        let nowTs = Int(selectedEndDate.timeIntervalSince1970)
        let todayStart = Int(selectedStartDate.timeIntervalSince1970)
        let selectedEnd = Int(selectedEndDate.timeIntervalSince1970)
        let lookbackStart = Int((calendar.date(byAdding: .day, value: -45, to: selectedStartDate) ?? selectedStartDate).timeIntervalSince1970)

        let stats = try await store.storageStats()
        let latest = try await store.latestHRSampleTs(deviceId: deviceId)

        let todayHR = try await store.hrSamples(deviceId: deviceId, from: todayStart, to: selectedEnd, limit: 120_000)
        let todayGravity = try await store.gravitySamples(deviceId: deviceId, from: todayStart, to: selectedEnd, limit: 120_000)
        let selectedDay = dayString(selectedStartDate, calendar: calendar)
        let loggedMetrics = try await loggedMetrics(store: store, deviceId: deviceId, day: selectedDay)
        let hasCurrentLoggedMetrics = Int(loggedMetrics["noop.logVersion"] ?? 0) >= dailyLogVersion
        if !selectedDayIsToday, hasCurrentLoggedMetrics, loggedMetrics["noop.finalized"] == 1 {
            var snapshot = loggedSnapshot(
                values: loggedMetrics,
                stats: stats,
                latest: latest,
                hr: todayHR
            )
            snapshot.activityPoints = todayGravity.count
            return snapshot
        }

        let sleepWindowStart = todayStart - 12 * 3600
        let sleepHR = try await store.hrSamples(deviceId: deviceId, from: sleepWindowStart, to: selectedEnd, limit: 160_000)
        let sleepRR = try await store.rrIntervals(deviceId: deviceId, from: sleepWindowStart, to: selectedEnd, limit: 240_000)
        let sleepResp = try await store.respSamples(deviceId: deviceId, from: sleepWindowStart, to: selectedEnd, limit: 160_000)
        let sleepGravity = try await store.gravitySamples(deviceId: deviceId, from: sleepWindowStart, to: selectedEnd, limit: 160_000)

        let historyHR = try await store.hrSamples(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        let historyRR = try await store.rrIntervals(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        let historyResp = try await store.respSamples(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        let historyGravity = try await store.gravitySamples(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        let historySpO2 = try await store.spo2Samples(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        let historySkinTemp = try await store.skinTempSamples(deviceId: deviceId, from: lookbackStart, to: nowTs, limit: 350_000)
        var storedSteps = loggedMetrics["noop.steps"] ?? loggedMetrics["steps"]
        if storedSteps == nil {
            storedSteps = try await store.metricSeries(deviceId: deviceId, key: "steps", from: selectedDay, to: selectedDay).last?.value
        }
        let strainHistoryStart = dayString(calendar.date(byAdding: .day, value: -28, to: selectedStartDate) ?? selectedStartDate, calendar: calendar)
        let strainHistoryEnd = dayString(calendar.date(byAdding: .day, value: -1, to: selectedStartDate) ?? selectedStartDate, calendar: calendar)
        let loggedStrainByDay = Dictionary(
            uniqueKeysWithValues: try await store
                .metricSeries(deviceId: deviceId, key: "strain", from: strainHistoryStart, to: strainHistoryEnd)
                .map { ($0.day, $0.value) }
        )

        let resting = restingHR(from: todayHR)
        let maxHR = StrainScorer.estimateHRmax(historyHR.map { Double($0.bpm) }, age: 30).0.nonZero
        let cachedSleep = hasCurrentLoggedMetrics ? loggedSleepSummary(from: loggedMetrics) : nil
        let manualWindow = manualSleepWindow(from: loggedMetrics)
        let sleepSummary: (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String)
        if !recalculateSleep, let cachedSleep {
            sleepSummary = cachedSleep
        } else if let manualWindow {
            sleepSummary = manualSleepSummary(
                start: manualWindow.start,
                end: manualWindow.end,
                hr: sleepHR,
                rr: sleepRR,
                resp: sleepResp,
                gravity: sleepGravity
            )
        } else {
            sleepSummary = whoopSleepSummary(
                hr: sleepHR,
                rr: sleepRR,
                resp: sleepResp,
                gravity: sleepGravity,
                selectedDayStart: todayStart,
                nowTs: selectedEnd
            )
        }
        let recoveryParts = (!recalculateSleep && cachedSleep != nil)
            ? (loggedRecoveryParts(from: loggedMetrics) ?? recovery(
                historyHR: historyHR,
                historyRR: historyRR,
                historyResp: historyResp,
                historyGravity: historyGravity,
                historySpO2: historySpO2,
                historySkinTemp: historySkinTemp,
                todayStart: todayStart,
                nowTs: nowTs,
                sleepSummary: sleepSummary,
                loggedStrainByDay: loggedStrainByDay,
                calendar: calendar
            ))
            : recovery(
                historyHR: historyHR,
                historyRR: historyRR,
                historyResp: historyResp,
                historyGravity: historyGravity,
                historySpO2: historySpO2,
                historySkinTemp: historySkinTemp,
                todayStart: todayStart,
                nowTs: nowTs,
                sleepSummary: sleepSummary,
                loggedStrainByDay: loggedStrainByDay,
                calendar: calendar
            )
        let awakeStart = awakeStartTs(for: todayStart, sleepIntervals: sleepSummary.intervals)
        let awakeHR = todayHR.filter { $0.ts >= awakeStart }
        let strain = dailyStrainValue(
            awakeHR,
            maxHR: maxHR,
            restingHR: Double(resting ?? 60),
            excluding: sleepSummary.intervals
        )
        let detected = WorkoutDetector.detect(
            hr: todayHR,
            gravity: todayGravity,
            restingHR: resting.map(Double.init),
            age: 30,
            profile: UserProfile(age: 30)
        )
        let workouts = detected.reversed().map { session in
            IOSDeviceWorkout(
                id: "\(session.start)-\(session.end)",
                start: Date(timeIntervalSince1970: TimeInterval(session.start)),
                end: Date(timeIntervalSince1970: TimeInterval(session.end)),
                durationMinutes: max(1, Int((session.durationS / 60.0).rounded())),
                avgHR: Int(session.avgHR.rounded()),
                maxHR: session.peakHR,
                strain: strainValue(
                    todayHR.filter { $0.ts >= session.start && $0.ts <= session.end },
                    gravity: todayGravity.filter { $0.ts >= session.start && $0.ts <= session.end },
                    maxHR: maxHR,
                    restingHR: Double(resting ?? 60),
                    excluding: sleepSummary.intervals
                ),
                calories: session.caloriesKcal
            )
        }

        let guidance = loadGuidance(
            historyHR: historyHR,
            historyGravity: historyGravity,
            selectedDayStart: todayStart,
            selectedDayStrain: strain,
            recovery: recoveryParts.score,
            calendar: calendar
        )

        var snapshot = IOSWhoopDeviceSnapshot()
        snapshot.decodedRows = stats.decodedRows
        snapshot.latestSampleAt = latest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        snapshot.status = status(decodedRows: stats.decodedRows, latest: snapshot.latestSampleAt)
        snapshot.strain = strain
        snapshot.recovery = recoveryParts.score
        snapshot.recoveryStatus = recoveryParts.status
        snapshot.restingHR = recoveryParts.restingHR ?? resting
        snapshot.hrvRMSSD = recoveryParts.hrv
        snapshot.whoopSleepHours = sleepSummary.hours
        snapshot.whoopSleepEfficiency = sleepSummary.efficiency
        snapshot.whoopSleepStages = sleepSummary.stages
        snapshot.whoopSleepIntervals = sleepSummary.intervals
        snapshot.whoopSleepStatus = sleepSummary.status
        snapshot.sleepHRVRMSSD = asleepHRV(hr: sleepHR, rr: sleepRR, resp: sleepResp, gravity: sleepGravity)
            ?? hrv(in: sleepRR, segments: healthSleepSegments(from: sleepSummary.intervals))
        snapshot.sleepSpO2RawRatio = recoveryParts.spo2RawRatio
        snapshot.sleepSkinTempRaw = recoveryParts.skinTempRaw
        snapshot.calories = workouts.compactMap(\.calories).reduce(0, +)
        snapshot.exerciseMinutes = workouts.reduce(0) { $0 + $1.durationMinutes }
        if let storedSteps {
            snapshot.steps = max(0, Int(storedSteps.rounded()))
            snapshot.stepsSource = "iPhone steps"
        } else {
            snapshot.steps = 0
            snapshot.stepsSource = "No iPhone steps logged"
        }
        snapshot.activityPoints = todayGravity.count
        snapshot.workouts = workouts
        snapshot.todayHRSamples = todayHR.enumerated().map { index, sample in
            IOSMetricHRSample(id: index, ts: sample.ts, bpm: sample.bpm)
        }
        snapshot.dailyHRSamples = sleepHR.enumerated().map { index, sample in
            IOSMetricHRSample(id: index, ts: sample.ts, bpm: sample.bpm)
        }
        snapshot.loadGuidance = guidance
        if !selectedDayIsToday, hasCurrentLoggedMetrics, !loggedMetrics.isEmpty {
            applyLoggedMetrics(loggedMetrics, to: &snapshot)
        }
        return snapshot
    }

    private static func awakeStartTs(for selectedDayStart: Int, sleepIntervals: [IOSSleepInterval]) -> Int {
        let morningCutoff = selectedDayStart + 14 * 3600
        let wakeTs = sleepIntervals
            .filter { $0.stage != "Awake" }
            .map { Int($0.end.timeIntervalSince1970) }
            .filter { $0 >= selectedDayStart && $0 <= morningCutoff }
            .max()
        return max(selectedDayStart, wakeTs ?? selectedDayStart)
    }

    private static func loggedMetrics(store: WhoopStore, deviceId: String, day: String) async throws -> [String: Double] {
        var keys = [
            "noop.logVersion",
            "noop.snapshotUpdatedAt",
            "noop.finalized",
            "strain",
            "recovery",
            "noop.adjustedLoad",
            "noop.sleepHours",
            "noop.sleepEfficiency",
            "noop.sleepStartTs",
            "noop.sleepEndTs",
            "noop.sleepIntervalCount",
            "noop.sleepManualStartTs",
            "noop.sleepManualEndTs",
            "noop.sleepManualUpdatedAt",
            "noop.sleepCoreHours",
            "noop.sleepDeepHours",
            "noop.sleepREMHours",
            "noop.sleepAwakeHours",
            "noop.exerciseMinutes",
            "noop.steps",
            "noop.activityPoints",
            "noop.calories",
            "noop.restingHR",
            "noop.hrvRMSSD",
            "noop.sleepHRVRMSSD",
            "noop.sleepSpO2RawRatio",
            "noop.sleepSkinTempRaw",
        ]
        for index in 0..<maxLoggedSleepIntervals {
            keys.append("noop.sleepInterval.\(index).startTs")
            keys.append("noop.sleepInterval.\(index).endTs")
            keys.append("noop.sleepInterval.\(index).stage")
        }
        var values: [String: Double] = [:]
        for key in keys {
            if let point = try await store.metricSeries(deviceId: deviceId, key: key, from: day, to: day).last {
                values[key] = point.value
            }
        }
        return values
    }

    private static func loggedSnapshot(values: [String: Double],
                                       stats: (decodedRows: Int, rawBatches: Int, rawBytes: Int),
                                       latest: Int?,
                                       hr: [HRSample]) -> IOSWhoopDeviceSnapshot {
        var snapshot = IOSWhoopDeviceSnapshot()
        snapshot.decodedRows = stats.decodedRows
        snapshot.latestSampleAt = latest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        snapshot.todayHRSamples = hr.enumerated().map { index, sample in
            IOSMetricHRSample(id: index, ts: sample.ts, bpm: sample.bpm)
        }
        snapshot.dailyHRSamples = snapshot.todayHRSamples
        applyLoggedMetrics(values, to: &snapshot)
        snapshot.status = values["noop.finalized"] == 1 ? "Final logged metrics" : "Logged metrics snapshot"
        return snapshot
    }

    private static func applyLoggedMetrics(_ values: [String: Double], to snapshot: inout IOSWhoopDeviceSnapshot) {
        if let strain = values["strain"] { snapshot.strain = strain }
        if let recovery = values["recovery"] { snapshot.recovery = recovery }
        if let sleepHours = values["noop.sleepHours"] { snapshot.whoopSleepHours = sleepHours }
        if let sleepEfficiency = values["noop.sleepEfficiency"] { snapshot.whoopSleepEfficiency = sleepEfficiency }
        applyLoggedSleep(values, to: &snapshot)
        if let exerciseMinutes = values["noop.exerciseMinutes"] { snapshot.exerciseMinutes = max(0, Int(exerciseMinutes.rounded())) }
        if let steps = values["noop.steps"] {
            snapshot.steps = max(0, Int(steps.rounded()))
            snapshot.stepsSource = "Logged daily snapshot"
        }
        if let activityPoints = values["noop.activityPoints"] { snapshot.activityPoints = max(0, Int(activityPoints.rounded())) }
        if let calories = values["noop.calories"] { snapshot.calories = calories }
        if let restingHR = values["noop.restingHR"] { snapshot.restingHR = max(0, Int(restingHR.rounded())) }
        if let hrv = values["noop.hrvRMSSD"] { snapshot.hrvRMSSD = hrv }
        if let sleepHRV = values["noop.sleepHRVRMSSD"] { snapshot.sleepHRVRMSSD = sleepHRV }
        if let spo2 = values["noop.sleepSpO2RawRatio"] { snapshot.sleepSpO2RawRatio = spo2 }
        if let skinTemp = values["noop.sleepSkinTempRaw"] { snapshot.sleepSkinTempRaw = skinTemp }
        if values["noop.finalized"] == 1 {
            snapshot.status = "Final logged metrics"
        } else if values["noop.snapshotUpdatedAt"] != nil {
            snapshot.status = "Logged metrics snapshot"
        }
    }

    private static func applyLoggedSleep(_ values: [String: Double], to snapshot: inout IOSWhoopDeviceSnapshot) {
        let stagePairs: [(String, String)] = [
            ("Core", "noop.sleepCoreHours"),
            ("Deep", "noop.sleepDeepHours"),
            ("REM", "noop.sleepREMHours"),
            ("Awake", "noop.sleepAwakeHours"),
        ]
        snapshot.whoopSleepStages = stagePairs.compactMap { name, key in
            guard let hours = values[key], hours > 0.01 else { return nil }
            return IOSSleepStageSummary(name: name, hours: hours)
        }
        if let storedIntervals = loggedSleepIntervals(from: values), !storedIntervals.isEmpty {
            snapshot.whoopSleepIntervals = storedIntervals
            if snapshot.whoopSleepStages.isEmpty {
                snapshot.whoopSleepStages = summarize(intervals: storedIntervals).stages
            }
            snapshot.whoopSleepStatus = "Logged sleep snapshot"
            return
        }
        guard let start = values["noop.sleepStartTs"],
              let end = values["noop.sleepEndTs"],
              end > start else { return }
        if snapshot.whoopSleepStages.isEmpty, snapshot.whoopSleepHours > 0 {
            snapshot.whoopSleepStages = [IOSSleepStageSummary(name: "Core", hours: snapshot.whoopSleepHours)]
        }
        snapshot.whoopSleepIntervals = snapshot.whoopSleepStages.reduce(into: []) { intervals, stage in
            let priorHours = intervals.reduce(0.0) { total, interval in
                total + interval.end.timeIntervalSince(interval.start) / 3600.0
            }
            let stageStart = Date(timeIntervalSince1970: start + priorHours * 3600.0)
            let stageEnd = min(
                Date(timeIntervalSince1970: end),
                Date(timeIntervalSince1970: stageStart.timeIntervalSince1970 + stage.hours * 3600.0)
            )
            if stageEnd > stageStart {
                intervals.append(IOSSleepInterval(start: stageStart, end: stageEnd, stage: stage.name))
            }
        }
        snapshot.whoopSleepStatus = "Logged sleep snapshot"
    }

    private static func loggedSleepIntervals(from values: [String: Double]) -> [IOSSleepInterval]? {
        let count = min(max(0, Int((values["noop.sleepIntervalCount"] ?? 0).rounded())), maxLoggedSleepIntervals)
        guard count > 0 else { return nil }
        let intervals = (0..<count).compactMap { index -> IOSSleepInterval? in
            guard let start = values["noop.sleepInterval.\(index).startTs"],
                  let end = values["noop.sleepInterval.\(index).endTs"],
                  let stageCode = values["noop.sleepInterval.\(index).stage"],
                  end > start else { return nil }
            return IOSSleepInterval(
                start: Date(timeIntervalSince1970: start),
                end: Date(timeIntervalSince1970: end),
                stage: sleepStageName(for: Int(stageCode.rounded()))
            )
        }
        return intervals.isEmpty ? nil : intervals.sorted { $0.start < $1.start }
    }

    private static func sleepStageName(for code: Int) -> String {
        switch code {
        case 0: return "Awake"
        case 2: return "Deep"
        case 3: return "REM"
        default: return "Core"
        }
    }

    private static func loggedSleepSummary(from values: [String: Double]) -> (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String)? {
        guard let start = values["noop.sleepStartTs"],
              let end = values["noop.sleepEndTs"],
              start > 0,
              end > start else { return nil }
        var snapshot = IOSWhoopDeviceSnapshot()
        snapshot.whoopSleepHours = max(0, values["noop.sleepHours"] ?? 0)
        snapshot.whoopSleepEfficiency = max(0, min(1, values["noop.sleepEfficiency"] ?? 0))
        applyLoggedSleep(values, to: &snapshot)
        guard !snapshot.whoopSleepIntervals.isEmpty else { return nil }
        let hours = snapshot.whoopSleepHours > 0
            ? snapshot.whoopSleepHours
            : snapshot.whoopSleepIntervals
                .filter { $0.stage != "Awake" }
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 3600.0 }
        let efficiency = snapshot.whoopSleepEfficiency > 0
            ? snapshot.whoopSleepEfficiency
            : min(1.0, max(0.0, hours / max((end - start) / 3600.0, 0.1)))
        let status = (values["noop.sleepManualUpdatedAt"] ?? 0) > 0
            ? "Adjusted sleep window"
            : "Logged sleep snapshot"
        return (hours, efficiency, snapshot.whoopSleepStages, snapshot.whoopSleepIntervals, status)
    }

    private static func manualSleepWindow(from values: [String: Double]) -> (start: Int, end: Int)? {
        guard let start = values["noop.sleepManualStartTs"],
              let end = values["noop.sleepManualEndTs"],
              start > 0,
              end - start >= 30 * 60 else { return nil }
        return (Int(start.rounded()), Int(end.rounded()))
    }

    private static func manualSleepSummary(start: Int,
                                           end: Int,
                                           hr: [HRSample],
                                           rr: [RRInterval],
                                           resp: [RespSample],
                                           gravity: [GravitySample]) -> (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String) {
        let staged = stageKnownSleepWindow(
            start: start,
            end: end,
            hr: hr,
            rr: rr,
            resp: resp,
            gravity: gravity,
            statusPrefix: "Adjusted sleep window"
        )
        let intervals = staged.intervals
        let safeIntervals = intervals.isEmpty
            ? [IOSSleepInterval(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                end: Date(timeIntervalSince1970: TimeInterval(end)),
                stage: "Core"
            )]
            : intervals
        let summary = summarize(intervals: safeIntervals)
        return (
            summary.hours,
            0.85,
            summary.stages,
            safeIntervals,
            staged.status
        )
    }

    private static func loggedRecoveryParts(from values: [String: Double]) -> (score: Double?, status: String, restingHR: Int?, hrv: Double?, spo2RawRatio: Double?, skinTempRaw: Double?)? {
        guard let recovery = values["recovery"] else { return nil }
        let restingHR = values["noop.restingHR"].map { max(0, Int($0.rounded())) }
        let hrv = values["noop.hrvRMSSD"]
        let spo2 = values["noop.sleepSpO2RawRatio"]
        let skinTemp = values["noop.sleepSkinTempRaw"]
        return (
            recovery,
            "Logged recovery snapshot from saved sleep window",
            restingHR,
            hrv,
            spo2,
            skinTemp
        )
    }

    private static func status(decodedRows: Int, latest: Date?) -> String {
        guard decodedRows > 0 else { return "No WHOOP samples stored yet" }
        guard let latest else { return "\(decodedRows) WHOOP rows stored" }
        let age = max(0, Date().timeIntervalSince(latest))
        if age < 10 * 60 { return "WHOOP data current" }
        if age < 2 * 3600 { return "Last WHOOP sample \(Int(age / 60)) min ago" }
        return "Last WHOOP sample \(Int(age / 3600)) h ago"
    }

    private static func restingHR(from hr: [HRSample]) -> Int? {
        guard !hr.isEmpty else { return nil }
        let sorted = hr.map(\.bpm).sorted()
        let index = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.10)))
        return sorted[index]
    }

    private static func estimatedSteps(from gravity: [GravitySample]) -> Int {
        let rows = gravity.sorted { $0.ts < $1.ts }
        guard rows.count >= 3 else { return 0 }

        var lastMagnitude = sqrt(rows[0].x * rows[0].x + rows[0].y * rows[0].y + rows[0].z * rows[0].z)
        var lastStepTs = 0
        var steps = 0

        for sample in rows.dropFirst() {
            let magnitude = sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z)
            let impulse = abs(magnitude - lastMagnitude)
            if impulse > 0.075 && sample.ts - lastStepTs >= 1 {
                steps += 1
                lastStepTs = sample.ts
            }
            lastMagnitude = magnitude
        }

        return steps
    }

    private static func asleepHRV(hr: [HRSample],
                                  rr: [RRInterval],
                                  resp: [RespSample],
                                  gravity: [GravitySample]) -> Double? {
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity)
        let asleepSegments = sessions.flatMap(\.stages).filter { $0.stage != "wake" && $0.end > $0.start }
        guard !asleepSegments.isEmpty else { return nil }
        let asleepRR = rr.filter { sample in
            asleepSegments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return HRVAnalyzer.analyze(asleepRR).rmssd
    }

    static func whoopSleepSummary(hr: [HRSample],
                                  rr: [RRInterval],
                                  resp: [RespSample],
                                  gravity: [GravitySample],
                                  selectedDayStart: Int,
                                  nowTs: Int) -> (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String) {
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity)
        let morningEnd = selectedDayStart + 14 * 3600
        let overnightStart = selectedDayStart - 8 * 3600
        let selectedSessions = sessions.filter { session in
            session.end >= selectedDayStart &&
                session.end <= morningEnd &&
                session.start >= overnightStart &&
                session.end <= nowTs + 2 * 3600
        }
        let stagedSegments = primaryOvernightSegments(from: selectedSessions)
        if !stagedSegments.isEmpty {
            return sleepSummary(from: stagedSegments, status: "WHOOP staged sleep from HR/R-R/motion")
        }

        return estimatedOvernightSleepSummary(
            hr: hr,
            rr: rr,
            resp: resp,
            gravity: gravity,
            selectedDayStart: selectedDayStart,
            nowTs: nowTs
        )
    }

    private static func sleepSummary(from segments: [StageSegment],
                                     status: String) -> (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String) {
        let segments = sleepCoreSegments(segments)
        guard !segments.isEmpty else { return (0, 0, [], [], "No sleep epochs inside detected overnight window") }
        var awake = 0.0
        var core = 0.0
        var deep = 0.0
        var rem = 0.0
        let intervals = segments.compactMap { segment -> IOSSleepInterval? in
            guard segment.end > segment.start else { return nil }
            let hours = Double(segment.end - segment.start) / 3600.0
            let label: String
            switch segment.stage.lowercased() {
            case "wake":
                awake += hours
                label = "Awake"
            case "deep":
                deep += hours
                label = "Deep"
            case "rem":
                rem += hours
                label = "REM"
            default:
                core += hours
                label = "Core"
            }
            return IOSSleepInterval(
                start: Date(timeIntervalSince1970: TimeInterval(segment.start)),
                end: Date(timeIntervalSince1970: TimeInterval(segment.end)),
                stage: label
            )
        }

        let hours = core + deep + rem
        let stages = [
            IOSSleepStageSummary(name: "Core", hours: core),
            IOSSleepStageSummary(name: "Deep", hours: deep),
            IOSSleepStageSummary(name: "REM", hours: rem),
            IOSSleepStageSummary(name: "Awake", hours: awake),
        ].filter { $0.hours > 0.01 }
        let inBed = max(0.0, Double((segments.last?.end ?? 0) - (segments.first?.start ?? 0)) / 3600.0)
        let efficiency = inBed > 0 ? min(1.0, max(0.0, hours / inBed)) : 0
        return (hours, efficiency, stages, intervals.sorted { $0.start < $1.start }, status)
    }

    private static func primaryOvernightSegments(from sessions: [SleepSession]) -> [StageSegment] {
        let candidates = sessions
            .map { session in
                (session: session, segments: sleepCoreSegments(session.stages))
            }
            .filter { !$0.segments.isEmpty }
        guard let primary = candidates.max(by: { asleepSeconds(in: $0.segments) < asleepSeconds(in: $1.segments) }) else {
            return []
        }

        let primaryStart = primary.segments.first?.start ?? primary.session.start
        let primaryEnd = primary.segments.last?.end ?? primary.session.end
        let maxFragmentGap = 90 * 60
        let nearby = candidates
            .filter { candidate in
                let start = candidate.segments.first?.start ?? candidate.session.start
                let end = candidate.segments.last?.end ?? candidate.session.end
                return start <= primaryEnd + maxFragmentGap && end >= primaryStart - maxFragmentGap
            }
            .sorted { ($0.segments.first?.start ?? $0.session.start) < ($1.segments.first?.start ?? $1.session.start) }

        var merged: [StageSegment] = []
        var previousEnd: Int?
        for candidate in nearby {
            guard let start = candidate.segments.first?.start,
                  let end = candidate.segments.last?.end,
                  end > start else { continue }
            if let previousEnd, start > previousEnd, start - previousEnd <= maxFragmentGap {
                merged.append(StageSegment(start: previousEnd, end: start, stage: "wake"))
            }
            merged.append(contentsOf: candidate.segments)
            previousEnd = max(previousEnd ?? end, end)
        }

        return sleepCoreSegments(merged)
    }

    private static func sleepCoreSegments(_ segments: [StageSegment]) -> [StageSegment] {
        let sorted = segments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard let firstSleep = sorted.firstIndex(where: { !isWakeStage($0.stage) }),
              let lastSleep = sorted.lastIndex(where: { !isWakeStage($0.stage) }) else { return [] }
        let start = sorted[firstSleep].start
        let end = sorted[lastSleep].end
        return sorted.compactMap { segment in
            let clippedStart = max(segment.start, start)
            let clippedEnd = min(segment.end, end)
            guard clippedEnd > clippedStart else { return nil }
            return StageSegment(start: clippedStart, end: clippedEnd, stage: segment.stage)
        }
    }

    private static func isWakeStage(_ stage: String) -> Bool {
        let normalized = stage.lowercased()
        return normalized == "wake" || normalized == "awake"
    }

    private static func asleepSeconds(in segments: [StageSegment]) -> Int {
        segments
            .filter { !isWakeStage($0.stage) && $0.end > $0.start }
            .reduce(0) { $0 + $1.end - $1.start }
    }

    private static func estimatedOvernightSleepSummary(hr: [HRSample],
                                                       rr: [RRInterval],
                                                       resp: [RespSample],
                                                       gravity: [GravitySample],
                                                       selectedDayStart: Int,
                                                       nowTs: Int) -> (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String) {
        let rows = hr
            .filter { $0.bpm >= 35 && $0.bpm <= 130 && $0.ts <= nowTs + 2 * 3600 }
            .sorted { $0.ts < $1.ts }
        guard rows.count >= 6 else { return (0, 0, [], [], "Only \(rows.count) overnight HR samples available") }

        let calendar = Calendar.current
        let nightRows = rows.filter { sample in
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(sample.ts)))
            return (hour >= 20 || hour <= 11) &&
                sample.ts >= selectedDayStart - 8 * 3600 &&
                sample.ts <= selectedDayStart + 12 * 3600
        }
        guard nightRows.count >= 6 else { return (0, 0, [], [], "Only \(nightRows.count) night HR samples available") }

        let sortedBPM = nightRows.map(\.bpm).sorted()
        let lowIndex = max(0, min(sortedBPM.count - 1, Int(Double(sortedBPM.count - 1) * 0.40)))
        let threshold = min(82, max(52, sortedBPM[lowIndex] + 6))
        let buckets = Dictionary(grouping: nightRows) { $0.ts / 300 }
            .map { bucket, samples in
                let avg = Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
                return (start: bucket * 300, end: bucket * 300 + 300, avg: avg, count: samples.count)
            }
            .filter { $0.count >= 2 }
            .sorted { $0.start < $1.start }

        var best: (start: Int, end: Int)?
        var current: (start: Int, end: Int)?
        for bucket in buckets {
            let isSleepLike = bucket.avg <= Double(threshold)
            if isSleepLike {
                if let run = current, bucket.start - run.end <= 30 * 60 {
                    current = (run.start, bucket.end)
                } else {
                    current = (bucket.start, bucket.end)
                }
            } else if let run = current {
                if best == nil || run.end - run.start > (best!.end - best!.start) {
                    best = run
                }
                current = nil
            }
        }
        if let run = current, best == nil || run.end - run.start > (best!.end - best!.start) {
            best = run
        }

        guard var run = best, run.end - run.start >= 60 * 60 else {
            return (0, 0, [], [], "No HR-only sleep run found without motion-confirmed sleep")
        }
        guard run.end >= selectedDayStart,
              run.end <= selectedDayStart + 12 * 3600 else {
            return (0, 0, [], [], "No HR-only sleep ending on this wake day")
        }

        run.start = max(run.start, nightRows.first?.ts ?? run.start)
        run.end = min(run.end, nightRows.last?.ts ?? run.end)
        let staged = stageKnownSleepWindow(
            start: run.start,
            end: run.end,
            hr: hr,
            rr: rr,
            resp: resp,
            gravity: gravity,
            statusPrefix: "Estimated overnight WHOOP sleep"
        )
        let intervals = staged.intervals
        let summary = summarize(intervals: intervals)
        let lowHRSummary = (
            summary.hours,
            0.85,
            summary.stages,
            intervals,
            "\(staged.status) (\(nightRows.count) HR samples)"
        )
        return lowHRSummary
    }

    private static func stageKnownSleepWindow(start: Int,
                                              end: Int,
                                              hr: [HRSample],
                                              rr: [RRInterval],
                                              resp: [RespSample],
                                              gravity: [GravitySample],
                                              statusPrefix: String) -> (intervals: [IOSSleepInterval], status: String) {
        let windowHR = hr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let windowRR = rr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let windowResp = resp.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let windowGravity = gravity.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }

        let duration = max(1, end - start)
        let gravitySpan = max(0, (windowGravity.last?.ts ?? start) - (windowGravity.first?.ts ?? start))
        let hasActigraphyCoverage = windowGravity.count >= 20 && Double(gravitySpan) >= Double(duration) * 0.50
        if hasActigraphyCoverage {
            let segments = SleepStager.stageSession(
                start: start,
                end: end,
                grav: windowGravity,
                hr: windowHR,
                rr: windowRR,
                resp: windowResp
            )
            let summary = sleepSummary(
                from: segments,
                status: "\(statusPrefix) staged from WHOOP \(sleepInputDescription(hr: windowHR, rr: windowRR, resp: windowResp, gravity: windowGravity))"
            )
            if !summary.intervals.isEmpty {
                return (summary.intervals, summary.status)
            }
        }

        let intervals = stageEstimatedSleep(
            start: start,
            end: end,
            hr: windowHR,
            rr: windowRR,
            fallbackStage: "Core"
        )
        let inputText = windowRR.count >= 20 ? "HR/R-R only" : "HR only"
        return (intervals, "\(statusPrefix) estimated from WHOOP \(inputText); stage confidence is lower without motion coverage")
    }

    private static func sleepInputDescription(hr: [HRSample],
                                              rr: [RRInterval],
                                              resp: [RespSample],
                                              gravity: [GravitySample]) -> String {
        var parts: [String] = []
        if !hr.isEmpty { parts.append("HR") }
        if rr.count >= 20 { parts.append("R-R") }
        if resp.count >= 30 { parts.append("respiration") }
        if gravity.count >= 20 { parts.append("motion") }
        return parts.isEmpty ? "available sensors" : parts.joined(separator: "/")
    }

    private static func stageEstimatedSleep(start: Int,
                                            end: Int,
                                            hr: [HRSample],
                                            rr: [RRInterval],
                                            fallbackStage: String) -> [IOSSleepInterval] {
        let epochS = 5 * 60
        var epochFeatures: [(start: Int, end: Int, hr: Double?, rmssd: Double?, hrSD: Double?)] = []
        var t = start
        while t < end {
            let e = min(t + epochS, end)
            let hrRows = hr.filter { $0.ts >= t && $0.ts < e }
            let rrRows = rr.filter { $0.ts >= t && $0.ts < e }.map { Double($0.rrMs) }
            let hrValues = hrRows.map { Double($0.bpm) }
            let meanHR = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)
            let hrSD = hrValues.count >= 3 ? sampleSD(hrValues) : nil
            let filteredRR = HRVAnalyzer.rangeFilter(rrRows)
            let rmssd = filteredRR.count >= 5 ? HRVAnalyzer.rmssdRaw(filteredRR) : nil
            epochFeatures.append((t, e, meanHR, rmssd, hrSD))
            t = e
        }

        let hrValues = epochFeatures.compactMap(\.hr)
        let rmssdValues = epochFeatures.compactMap(\.rmssd)
        let hrSDValues = epochFeatures.compactMap(\.hrSD)
        let hrVeryLow = percentile(hrValues, 0.15)
        let hrLow = percentile(hrValues, 0.25)
        let hrHigh = percentile(hrValues, 0.70)
        let rmssdHigh = percentile(rmssdValues, 0.70)
        let rmssdLow = percentile(rmssdValues, 0.30)
        let hrSDQuiet = percentile(hrSDValues, 0.40)
        let hrSDHigh = percentile(hrSDValues, 0.65)
        let firstThirdEnd = start + max(1, (end - start) / 3)
        let firstREMLatencyEnd = start + 70 * 60

        var labeled: [(start: Int, end: Int, stage: String)] = epochFeatures.map { epoch in
            guard let hrValue = epoch.hr else {
                return (epoch.start, epoch.end, fallbackStage)
            }
            let rmssd = epoch.rmssd
            let hrSD = epoch.hrSD
            let earlyNight = epoch.start < firstThirdEnd
            let remAllowed = epoch.start >= firstREMLatencyEnd
            let lowHR = hrLow.map { hrValue <= $0 } ?? false
            let veryLowHR = hrVeryLow.map { hrValue <= $0 } ?? false
            let highHR = hrHigh.map { hrValue >= $0 } ?? false
            let highRMSSD = rmssd.flatMap { value in rmssdHigh.map { value >= $0 } } ?? false
            let lowRMSSD = rmssd.flatMap { value in rmssdLow.map { value <= $0 } } ?? false
            let quietHR = hrSD.flatMap { value in hrSDQuiet.map { value <= $0 } } ?? false
            let variableHR = hrSD.flatMap { value in hrSDHigh.map { value >= $0 } } ?? false
            let stage: String
            if earlyNight && ((lowHR && highRMSSD) || (veryLowHR && quietHR)) {
                stage = "Deep"
            } else if remAllowed && highHR && (lowRMSSD || variableHR || rmssd == nil) {
                stage = "REM"
            } else {
                stage = "Core"
            }
            return (epoch.start, epoch.end, stage)
        }

        if !labeled.contains(where: { $0.stage == "Deep" }),
           let hrLow,
           let index = epochFeatures.firstIndex(where: { epoch in
               guard epoch.start < firstThirdEnd,
                     let hr = epoch.hr,
                     hr <= hrLow else { return false }
               if let rmssd = epoch.rmssd, let rmssdHigh {
                   return rmssd >= rmssdHigh
               }
               if let veryLow = hrVeryLow, let hrSD = epoch.hrSD, let quiet = hrSDQuiet {
                   return hr <= veryLow && hrSD <= quiet
               }
               return false
           }) {
            labeled[index].stage = "Deep"
        }

        if !labeled.contains(where: { $0.stage == "REM" }),
           let hrHigh,
           let index = epochFeatures.lastIndex(where: { epoch in
               guard epoch.start >= firstREMLatencyEnd,
                     let hr = epoch.hr,
                     hr >= hrHigh else { return false }
               if let rmssd = epoch.rmssd, let rmssdLow {
                   return rmssd <= rmssdLow
               }
               if let hrSD = epoch.hrSD, let high = hrSDHigh {
                   return hrSD >= high
               }
               return true
           }) {
            labeled[index].stage = "REM"
        }

        return mergeIntervals(labeled.map {
            IOSSleepInterval(
                start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                end: Date(timeIntervalSince1970: TimeInterval($0.end)),
                stage: $0.stage
            )
        })
    }

    private static func mergeIntervals(_ intervals: [IOSSleepInterval]) -> [IOSSleepInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var merged: [IOSSleepInterval] = []
        for interval in sorted.dropFirst() {
            if interval.stage == current.stage && interval.start.timeIntervalSince(current.end) <= 1 {
                current = IOSSleepInterval(start: current.start, end: interval.end, stage: current.stage)
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    private static func summarize(intervals: [IOSSleepInterval]) -> (hours: Double, stages: [IOSSleepStageSummary]) {
        var core = 0.0
        var deep = 0.0
        var rem = 0.0
        var awake = 0.0
        for interval in intervals {
            let h = interval.end.timeIntervalSince(interval.start) / 3600.0
            switch interval.stage {
            case "Deep": deep += h
            case "REM": rem += h
            case "Awake": awake += h
            default: core += h
            }
        }
        return (
            core + deep + rem,
            [
                IOSSleepStageSummary(name: "Core", hours: core),
                IOSSleepStageSummary(name: "Deep", hours: deep),
                IOSSleepStageSummary(name: "REM", hours: rem),
                IOSSleepStageSummary(name: "Awake", hours: awake),
            ].filter { $0.hours > 0.01 }
        )
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private static func recovery(historyHR: [HRSample],
                                 historyRR: [RRInterval],
                                 historyResp: [RespSample],
                                 historyGravity: [GravitySample],
                                 historySpO2: [SpO2Sample],
                                 historySkinTemp: [SkinTempSample],
                                 todayStart: Int,
                                 nowTs: Int,
                                 sleepSummary: (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String),
                                 loggedStrainByDay: [String: Double],
                                 calendar: Calendar) -> (score: Double?, status: String, restingHR: Int?, hrv: Double?, spo2RawRatio: Double?, skinTempRaw: Double?) {
        let currentStart = max(todayStart - 12 * 3600, nowTs - 18 * 3600)
        let sessions = SleepStager.detectSleep(hr: historyHR, rr: historyRR, resp: historyResp, gravity: historyGravity)
        let currentSession = sessions
            .filter { $0.end >= currentStart && $0.end <= nowTs + 2 * 3600 }
            .max { $0.end < $1.end }
        let whoopSegments = healthSleepSegments(from: sleepSummary.intervals)
        let currentSegments = whoopSegments.isEmpty ? (currentSession.map(asleepSegments) ?? []) : whoopSegments
        let currentWindowStart = currentSegments.map(\.start).min() ?? currentStart
        let currentWindowEnd = currentSegments.map(\.end).max() ?? nowTs
        let currentHRV = hrv(in: historyRR, segments: currentSegments)
            ?? HRVAnalyzer.analyze(historyRR, windowStart: currentWindowStart, windowEnd: currentWindowEnd).rmssd
        let currentRHR = restingHR(in: historyHR, segments: currentSegments)
            ?? RecoveryScorer.restingHR(historyHR, start: currentWindowStart, end: currentWindowEnd)
        let currentResp = respiratoryRate(in: historyResp, segments: currentSegments)
        let currentSpO2Raw = spO2RawRatio(in: historySpO2, segments: currentSegments)
            ?? spO2RawRatio(from: historySpO2.filter { $0.ts >= currentWindowStart && $0.ts <= currentWindowEnd })
        let currentSkinRaw = skinTempRaw(in: historySkinTemp, segments: currentSegments)
            ?? skinTempRaw(from: historySkinTemp.filter { $0.ts >= currentWindowStart && $0.ts <= currentWindowEnd })

        var hrvNights: [Double?] = []
        var rhrNights: [Double?] = []
        var respNights: [Double?] = []
        var spO2RawNights: [Double?] = []
        var skinRawNights: [Double?] = []
        for offset in stride(from: 30, through: 1, by: -1) {
            let dayStart = todayStart - offset * 24 * 3600
            let nightStart = dayStart - 4 * 3600
            let nightEnd = dayStart + 10 * 3600
            let nightSession = sessions
                .filter { $0.end >= nightStart && $0.end <= nightEnd + 4 * 3600 }
                .max { $0.end < $1.end }
            let segments = nightSession.map(asleepSegments) ?? []
            if segments.isEmpty {
                hrvNights.append(HRVAnalyzer.analyze(historyRR, windowStart: nightStart, windowEnd: nightEnd).rmssd)
                rhrNights.append(RecoveryScorer.restingHR(historyHR, start: nightStart, end: nightEnd).map(Double.init))
                respNights.append(respiratoryRate(in: historyResp, start: nightStart, end: nightEnd))
                spO2RawNights.append(spO2RawRatio(from: historySpO2.filter { $0.ts >= nightStart && $0.ts <= nightEnd }))
                skinRawNights.append(skinTempRaw(from: historySkinTemp.filter { $0.ts >= nightStart && $0.ts <= nightEnd }))
            } else {
                hrvNights.append(hrv(in: historyRR, segments: segments))
                rhrNights.append(restingHR(in: historyHR, segments: segments).map(Double.init))
                respNights.append(respiratoryRate(in: historyResp, segments: segments))
                spO2RawNights.append(spO2RawRatio(in: historySpO2, segments: segments))
                skinRawNights.append(skinTempRaw(in: historySkinTemp, segments: segments))
            }
        }

        let hrvBaseline = Baselines.foldHistory(hrvNights, cfg: Baselines.hrvCfg)
        let rhrBaseline = Baselines.foldHistory(rhrNights, cfg: Baselines.restingHRCfg)
        let respBaseline = Baselines.foldHistory(respNights, cfg: Baselines.respCfg)
        let rawSpO2Context = rawContext(currentSpO2Raw, history: spO2RawNights)
        let rawSkinContext = rawContext(currentSkinRaw, history: skinRawNights)
        let illnessPenalty = illnessPenaltyZ(spO2: currentSpO2Raw, spO2History: spO2RawNights, skin: currentSkinRaw, skinHistory: skinRawNights)
        let loadRatio = acuteChronicStrainRatio(
            historyHR: historyHR,
            historyGravity: historyGravity,
            selectedDayStart: todayStart,
            loggedStrainByDay: loggedStrainByDay,
            calendar: calendar
        )
        let sleepPerf = sleepPerformance(summary: sleepSummary)

        guard let currentHRV, let currentRHR else {
            return (nil, "Waiting for overnight WHOOP R-R and HR data", currentRHR, currentHRV, currentSpO2Raw, currentSkinRaw)
        }

        let score = RecoveryScorer.recovery(
            hrv: currentHRV,
            rhr: Double(currentRHR),
            resp: currentResp,
            hrvBaseline: hrvBaseline,
            rhrBaseline: rhrBaseline,
            respBaseline: respBaseline,
            sleepPerf: sleepPerf,
            acuteChronicLoadRatio: loadRatio,
            illnessPenaltyZ: illnessPenalty
        )

        guard let score else {
            let provisional = provisionalRecoveryScore(
                sleepPerf: sleepPerf,
                loadRatio: loadRatio,
                illnessPenalty: illnessPenalty
            )
            return (
                provisional,
                "Provisional NOOP recovery while WHOOP baseline calibrates \(hrvBaseline.nValid)/\(Baselines.minNightsSeed) nights",
                currentRHR,
                currentHRV,
                currentSpO2Raw,
                currentSkinRaw
            )
        }
        let respText = currentResp == nil ? "" : "/respiration"
        let loadText = loadRatio.map { String(format: ", load %.2fx", $0) } ?? ""
        let illnessText = illnessPenalty.map { $0 >= 1.0 ? ", illness watch" : "" } ?? ""
        let rawText = [rawSpO2Context.map { "raw SpO2 \($0)" }, rawSkinContext.map { "skin ADC \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
        let suffix = rawText.isEmpty ? "" : " (\(rawText))"
        return (score, "NOOP recovery from WHOOP sleep, HRV/RHR\(respText)\(loadText)\(illnessText)\(suffix)", currentRHR, currentHRV, currentSpO2Raw, currentSkinRaw)
    }

    private static func sleepPerformance(summary: (hours: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval], status: String)) -> Double? {
        guard summary.hours > 0 else { return nil }
        let duration = min(1.0, summary.hours / 8.0)
        let efficiency = min(1.0, max(0.0, summary.efficiency) / 0.85)
        let deep = summary.stages.first { $0.name == "Deep" }?.hours ?? 0
        let rem = summary.stages.first { $0.name == "REM" }?.hours ?? 0
        let restorative = min(1.0, ((deep + rem) / max(summary.hours, 0.1)) / 0.35)
        return max(0.0, min(1.0, duration * 0.55 + efficiency * 0.25 + restorative * 0.20))
    }

    private static func provisionalRecoveryScore(sleepPerf: Double?,
                                                 loadRatio: Double?,
                                                 illnessPenalty: Double?) -> Double? {
        guard sleepPerf != nil || loadRatio != nil || illnessPenalty != nil else { return nil }
        let sleepZ = sleepPerf.map { ($0 - RecoveryScorer.sleepPerfCenter) / RecoveryScorer.sleepPerfScale } ?? 0
        let loadZ = RecoveryScorer.loadZ(acuteChronicRatio: loadRatio) ?? 0
        let illnessZ = illnessPenalty.map { -min(3.0, max(0.0, $0)) } ?? 0
        let z = sleepZ * 0.65 + loadZ * 0.20 + illnessZ * 0.15
        let score = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    private static func acuteChronicStrainRatio(historyHR: [HRSample],
                                                historyGravity: [GravitySample],
                                                selectedDayStart: Int,
                                                loggedStrainByDay: [String: Double],
                                                calendar: Calendar) -> Double? {
        let maxHR = StrainScorer.estimateHRmax(historyHR.map { Double($0.bpm) }, age: 30).0.nonZero
        let sleepSessions = SleepStager.detectSleep(hr: historyHR, gravity: historyGravity)
        var strains: [Double] = []
        for offset in stride(from: 28, through: 1, by: -1) {
            let start = selectedDayStart - offset * 24 * 3600
            let end = start + 24 * 3600 - 1
            let day = dayString(Date(timeIntervalSince1970: TimeInterval(start)), calendar: calendar)
            if let logged = loggedStrainByDay[day] {
                strains.append(max(0, logged))
                continue
            }
            let dayHR = historyHR.filter { $0.ts >= start && $0.ts <= end }
            let resting = restingHR(from: dayHR).map(Double.init) ?? 60
            let sleepIntervals = sleepSessions
                .filter { $0.end >= start && $0.start <= end }
                .flatMap { session in
                    session.stages
                        .filter { $0.stage != "wake" && $0.end > $0.start }
                        .map {
                            IOSSleepInterval(
                                start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                                end: Date(timeIntervalSince1970: TimeInterval($0.end)),
                                stage: $0.stage
                            )
                        }
                }
            strains.append(dailyStrainValue(dayHR, maxHR: maxHR, restingHR: resting, excluding: sleepIntervals) ?? 0)
        }
        let nonZero = strains.filter { $0 > 0 }
        guard nonZero.count >= 14 else { return nil }
        let acute = strains.suffix(7).reduce(0, +) / 7.0
        let chronic = strains.reduce(0, +) / Double(strains.count)
        guard chronic > 0 else { return nil }
        return acute / chronic
    }

    private static func illnessPenaltyZ(spO2: Double?, spO2History: [Double?], skin: Double?, skinHistory: [Double?]) -> Double? {
        let penalties = [
            rawAbsZ(spO2, history: spO2History),
            rawAbsZ(skin, history: skinHistory)
        ].compactMap { $0 }.map { max(0.0, $0 - 1.0) }
        guard !penalties.isEmpty else { return nil }
        return min(3.0, penalties.max() ?? 0)
    }

    private static func rawAbsZ(_ current: Double?, history: [Double?]) -> Double? {
        guard let current else { return nil }
        let values = history.compactMap { $0 }
        guard values.count >= Baselines.minNightsSeed, let avg = mean(values) else { return nil }
        let sd = sampleSD(values) ?? 0
        guard sd > 0 else { return nil }
        return abs((current - avg) / sd)
    }

    private static func asleepSegments(_ session: SleepSession) -> [StageSegment] {
        session.stages.filter { $0.stage != "wake" && $0.end > $0.start }
    }

    private static func healthSleepSegments(from intervals: [IOSSleepInterval]) -> [StageSegment] {
        intervals.compactMap { interval in
            guard interval.stage != "Awake", interval.end > interval.start else { return nil }
            return StageSegment(
                start: Int(interval.start.timeIntervalSince1970),
                end: Int(interval.end.timeIntervalSince1970),
                stage: interval.stage.lowercased()
            )
        }
    }

    private static func hrv(in rr: [RRInterval], segments: [StageSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let rows = rr.filter { sample in
            segments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return HRVAnalyzer.analyze(rows).rmssd
    }

    private static func restingHR(in hr: [HRSample], segments: [StageSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        let rows = hr.filter { sample in
            segments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return restingHR(from: rows)
    }

    private static func respiratoryRate(in resp: [RespSample], segments: [StageSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let rows = resp.filter { sample in
            segments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return respiratoryRate(from: rows)
    }

    private static func spO2RawRatio(in samples: [SpO2Sample], segments: [StageSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let rows = samples.filter { sample in
            segments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return spO2RawRatio(from: rows)
    }

    private static func spO2RawRatio(from samples: [SpO2Sample]) -> Double? {
        let ratios = samples.compactMap { sample -> Double? in
            guard sample.ir > 0 else { return nil }
            return Double(sample.red) / Double(sample.ir)
        }
        return mean(ratios)
    }

    private static func skinTempRaw(in samples: [SkinTempSample], segments: [StageSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let rows = samples.filter { sample in
            segments.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
        return skinTempRaw(from: rows)
    }

    private static func skinTempRaw(from samples: [SkinTempSample]) -> Double? {
        mean(samples.map { Double($0.raw) })
    }

    private static func rawContext(_ current: Double?, history: [Double?]) -> String? {
        guard let current else { return nil }
        let values = history.compactMap { $0 }
        guard values.count >= Baselines.minNightsSeed, let avg = mean(values) else {
            return "raw \(String(format: "%.2f", current))"
        }
        let sd = sampleSD(values) ?? 0
        guard sd > 0 else { return "raw \(String(format: "%.2f", current))" }
        let z = (current - avg) / sd
        return String(format: "z%+.1f", z)
    }

    private static func respiratoryRate(in resp: [RespSample], start: Int, end: Int) -> Double? {
        respiratoryRate(from: resp.filter { $0.ts >= start && $0.ts <= end })
    }

    private static func respiratoryRate(from resp: [RespSample]) -> Double? {
        let rows = resp.sorted { $0.ts < $1.ts }
        guard rows.count >= 12 else { return nil }
        let values = rows.map { Double($0.raw) }
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        var peaks: [Int] = []
        var lastPeakTs = Int.min / 2
        for i in 1..<(centered.count - 1) {
            guard centered[i] > 0,
                  centered[i] >= centered[i - 1],
                  centered[i] > centered[i + 1],
                  rows[i].ts - lastPeakTs >= 2 else { continue }
            peaks.append(rows[i].ts)
            lastPeakTs = rows[i].ts
        }
        guard peaks.count >= 3 else { return nil }
        let intervals = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) }.filter { $0 >= 1.5 && $0 <= 12.0 }
        guard let median = median(intervals), median > 0 else { return nil }
        let rate = 60.0 / median
        return (4...40).contains(rate) ? rate : nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let clamped = min(1.0, max(0.0, fraction))
        let pos = clamped * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = Int(ceil(pos))
        guard lo != hi else { return sorted[lo] }
        let weight = pos - Double(lo)
        return sorted[lo] * (1 - weight) + sorted[hi] * weight
    }

    private static func sampleSD(_ values: [Double]) -> Double? {
        guard values.count >= 2, let avg = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - avg, 2) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    private static func loadGuidance(historyHR: [HRSample],
                                     historyGravity: [GravitySample],
                                     selectedDayStart: Int,
                                     selectedDayStrain: Double?,
                                     recovery: Double?,
                                     calendar: Calendar) -> IOSLoadGuidance {
        let sleepSessions = SleepStager.detectSleep(hr: historyHR, gravity: historyGravity)
        var dayStrains: [Double] = []
        for offset in stride(from: 28, through: 0, by: -1) {
            let start = selectedDayStart - offset * 24 * 3600
            let end = start + 24 * 3600 - 1
            let dayHR = historyHR.filter { $0.ts >= start && $0.ts <= end }
            let resting = restingHR(from: dayHR).map(Double.init) ?? 60
            let sleepIntervals = sleepSessions
                .filter { $0.end >= start && $0.start <= end }
                .flatMap { session in
                    session.stages
                        .filter { $0.stage != "wake" && $0.end > $0.start }
                        .map {
                            IOSSleepInterval(
                                start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                                end: Date(timeIntervalSince1970: TimeInterval($0.end)),
                                stage: $0.stage
                            )
                        }
                }
            let strain = dailyStrainValue(
                dayHR,
                maxHR: StrainScorer.estimateHRmax(historyHR.map { Double($0.bpm) }, age: 30).0.nonZero,
                restingHR: resting,
                excluding: sleepIntervals
            )
            dayStrains.append(strain ?? 0)
        }

        let nonZeroHistory = dayStrains.dropLast().filter { $0 > 0 }
        guard nonZeroHistory.count >= 14 else {
            return IOSLoadGuidance()
        }

        let acute = dayStrains.suffix(7).reduce(0, +) / 7.0
        let chronicValues = dayStrains.suffix(28)
        let chronic = chronicValues.reduce(0, +) / Double(chronicValues.count)
        guard chronic > 0 else { return IOSLoadGuidance() }

        let acwr = acute / chronic
        let targetLow = max(0, chronic * 0.8)
        let targetHigh = min(21, chronic * 1.3)

        let title: String
        let detail: String
        let colorKey: String
        switch acwr {
        case ..<0.8:
            title = "Room to build"
            detail = "ACWR \(String(format: "%.2f", acwr)): recent load is below your chronic base."
            colorKey = "watch"
        case 0.8..<1.3:
            title = "Productive load"
            detail = "ACWR \(String(format: "%.2f", acwr)): recent load is in the supported range."
            colorKey = "good"
        case 1.3..<1.5:
            title = "Building fast"
            detail = "ACWR \(String(format: "%.2f", acwr)): watch fatigue as load rises."
            colorKey = "watch"
        default:
            title = "Load spike"
            detail = "ACWR \(String(format: "%.2f", acwr)): recent load is high versus your base."
            colorKey = "bad"
        }

        _ = selectedDayStrain
        _ = calendar
        return IOSLoadGuidance(
            title: title,
            detail: detail,
            acwr: acwr,
            targetLow: targetLow,
            targetHigh: targetHigh,
            colorKey: colorKey
        )
    }

    private static func strainValue(_ hr: [HRSample],
                                    gravity: [GravitySample],
                                    maxHR: Double?,
                                    restingHR: Double,
                                    excluding sleepIntervals: [IOSSleepInterval] = []) -> Double? {
        let filteredHR = excludingSleep(hr, intervals: sleepIntervals)
        let filteredGravity = excludingSleep(gravity, intervals: sleepIntervals)
        return IOSStrainEstimator.strain(
            hr: filteredHR,
            gravity: filteredGravity,
            maxHR: maxHR,
            restingHR: restingHR
        )
    }

    private static func dailyStrainValue(_ hr: [HRSample],
                                         maxHR: Double?,
                                         restingHR: Double,
                                         excluding sleepIntervals: [IOSSleepInterval] = []) -> Double? {
        let filteredHR = excludingSleep(hr, intervals: sleepIntervals)
        return IOSStrainEstimator.awakeDayStrain(
            hr: filteredHR,
            maxHR: maxHR,
            restingHR: restingHR
        )
    }

    private static func excludingSleep(_ hr: [HRSample], intervals: [IOSSleepInterval]) -> [HRSample] {
        guard !intervals.isEmpty else { return hr }
        let ranges = sleepRanges(from: intervals)
        return hr.filter { sample in
            !ranges.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
    }

    private static func excludingSleep(_ gravity: [GravitySample], intervals: [IOSSleepInterval]) -> [GravitySample] {
        guard !intervals.isEmpty else { return gravity }
        let ranges = sleepRanges(from: intervals)
        return gravity.filter { sample in
            !ranges.contains { sample.ts >= $0.start && sample.ts <= $0.end }
        }
    }

    private static func sleepRanges(from intervals: [IOSSleepInterval]) -> [(start: Int, end: Int)] {
        intervals.compactMap { interval in
            guard interval.stage != "Awake", interval.end > interval.start else { return nil }
            return (
                start: Int(interval.start.timeIntervalSince1970),
                end: Int(interval.end.timeIntervalSince1970)
            )
        }
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
