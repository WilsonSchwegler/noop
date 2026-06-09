import Foundation
import HealthKit
import StrandAnalytics
import WhoopProtocol
import WhoopStore

struct IOSSleepStageSummary: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let hours: Double
}

struct IOSSleepInterval: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let stage: String
}

@MainActor
final class IOSHealthStore: ObservableObject {
    @Published var isAvailable = HKHealthStore.isHealthDataAvailable()
    @Published var isAuthorized = false
    @Published var status = "Health access not requested"
    @Published var sleepHours = 0.0
    @Published var sleepScore: Int?
    @Published var sleepEfficiency = 0.0
    @Published var sleepStages: [IOSSleepStageSummary] = []
    @Published var sleepIntervals: [IOSSleepInterval] = []
    @Published var exportStatus = "WHOOP export not run"
    @Published var isExporting = false

    private let store = HKHealthStore()

    func requestAccessAndRefresh() {
        guard isAvailable else {
            status = "HealthKit is not available on this device"
            return
        }

        store.requestAuthorization(toShare: [], read: Self.readTypes) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthorized = success
                self.status = success ? "Health access enabled" : (error?.localizedDescription ?? "Health access denied")
                if success { self.refresh() }
            }
        }
    }

    func refresh(for date: Date = Date()) {
        fetchSleep(for: date)
    }

    func exportWhoopData(store whoopStore: WhoopStore, deviceId: String) {
        guard isAvailable else {
            exportStatus = "HealthKit is not available on this device"
            return
        }
        guard !isExporting else { return }

        isExporting = true
        exportStatus = "Requesting Apple Health write access"

        Task { @MainActor in
            do {
                try await requestExportAuthorization()
                exportStatus = "Reading WHOOP data"
                let result = try await Self.buildHealthObjects(from: whoopStore, deviceId: deviceId)
                guard !result.objects.isEmpty else {
                    exportStatus = "No WHOOP data ready to export"
                    isExporting = false
                    return
                }
                if let sleepWindow = result.sleepWindow, result.sleepCount > 0 {
                    exportStatus = "Replacing prior NOOP sleep export"
                    try await deletePriorNoopSleepSamples(overlapping: sleepWindow)
                }
                try await save(result.objects)
                exportStatus = "Exported \(result.hrCount) HR, \(result.sleepCount) sleep, \(result.workoutCount) workout, \(result.hrvCount) HRV, \(result.respCount) respiration samples"
                isAuthorized = true
                refresh()
            } catch {
                exportStatus = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private func fetchSleep(for date: Date = Date()) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let dayStart = Calendar.current.startOfDay(for: date)
        let start = Calendar.current.date(byAdding: .hour, value: -18, to: dayStart) ?? dayStart
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            let categorySamples = (samples as? [HKCategorySample]) ?? []
            let totals = Self.sleepTotals(from: categorySamples)
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.applySleepTotals(totals)
                    self.status = "Health sleep read failed: \(error.localizedDescription)"
                } else if totals.total > 0 {
                    self.applySleepTotals(totals)
                    self.isAuthorized = true
                    self.status = "Health sleep loaded (\(categorySamples.count) records)"
                } else {
                    self.fetchMostRecentSleepFallback(type: type, before: end)
                }
            }
        }
        store.execute(query)
    }

    private func applySleepTotals(_ totals: (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval])) {
        sleepHours = totals.total
        sleepEfficiency = totals.efficiency
        sleepScore = Self.sleepScore(hours: totals.total, efficiency: totals.efficiency)
        sleepStages = totals.stages
        sleepIntervals = totals.intervals
    }

    private func fetchMostRecentSleepFallback(type: HKCategoryType, before end: Date) {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            let categorySamples = (samples as? [HKCategorySample]) ?? []
            let recentSamples = Self.mostRecentSleepCluster(from: categorySamples)
            let totals = Self.sleepTotals(from: recentSamples)
            Task { @MainActor in
                guard let self else { return }
                self.applySleepTotals(totals)
                if let error {
                    self.status = "Health sleep fallback failed: \(error.localizedDescription)"
                } else if totals.total > 0 {
                    self.isAuthorized = true
                    self.status = "Loaded latest Health sleep from last 7 days (\(recentSamples.count) records)"
                } else if categorySamples.isEmpty {
                    self.status = "No Apple Health sleep records readable by NOOP"
                } else {
                    self.status = "Health returned \(categorySamples.count) sleep records, but no asleep intervals"
                }
            }
        }
        store.execute(query)
    }

    private static var readTypes: Set<HKObjectType> {
        Set([HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 })
    }

    private static var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let resp = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { types.insert(resp) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    private func requestExportAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.authorizationDenied)
                }
            }
        }
    }

    private func save(_ objects: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(objects) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.saveFailed)
                }
            }
        }
    }

    private func deletePriorNoopSleepSamples(overlapping window: DateInterval) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let start = window.start.addingTimeInterval(-2 * 3600)
        let end = window.end.addingTimeInterval(2 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let noopSleep = ((samples as? [HKCategorySample]) ?? []).filter { sample in
                    let source = sample.metadata?["NOOPSource"] as? String
                    let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                    return source == "WHOOP" && syncID?.hasPrefix("noop.whoop.sleep.") == true
                }
                continuation.resume(returning: noopSleep)
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.delete(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.deleteFailed)
                }
            }
        }
    }

    private static func buildHealthObjects(from store: WhoopStore, deviceId: String) async throws
        -> (objects: [HKObject], hrCount: Int, sleepCount: Int, workoutCount: Int, hrvCount: Int, respCount: Int, sleepWindow: DateInterval?) {
        let now = Int(Date().timeIntervalSince1970)
        let start = now - 48 * 3600

        let hr = try await store.hrSamples(deviceId: deviceId, from: start, to: now, limit: 25_000)
        let rr = try await store.rrIntervals(deviceId: deviceId, from: start, to: now, limit: 100_000)
        let resp = try await store.respSamples(deviceId: deviceId, from: start, to: now, limit: 25_000)
        let gravity = try await store.gravitySamples(deviceId: deviceId, from: start, to: now, limit: 25_000)

        var objects: [HKObject] = []
        let hrObjects = heartRateSamples(from: hr)
        let sleepObjects = sleepSamples(hr: hr, rr: rr, resp: resp, gravity: gravity)
        let hrvObjects = hrvSamples(from: rr)
        let respObjects = respiratoryRateSamples(from: resp)
        let workoutObjects = workoutSamples(hr: hr, gravity: gravity)
        objects.append(contentsOf: hrObjects)
        objects.append(contentsOf: sleepObjects)
        objects.append(contentsOf: hrvObjects)
        objects.append(contentsOf: respObjects)
        objects.append(contentsOf: workoutObjects)
        let sleepStart = sleepObjects.map(\.startDate).min()
        let sleepEnd = sleepObjects.map(\.endDate).max()
        let sleepWindow = sleepStart.flatMap { start in
            sleepEnd.map { DateInterval(start: start, end: $0) }
        }
        return (objects, hrObjects.count, sleepObjects.count, workoutObjects.count, hrvObjects.count, respObjects.count, sleepWindow)
    }

    private static func heartRateSamples(from samples: [HRSample]) -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.map { sample in
            let start = Date(timeIntervalSince1970: TimeInterval(sample.ts))
            let end = start.addingTimeInterval(1)
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: Double(sample.bpm)),
                start: start,
                end: end,
                metadata: syncMetadata("hr.\(sample.ts).\(sample.bpm)")
            )
        }
    }

    private static func hrvSamples(from rr: [RRInterval]) -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return [] }
        let unit = HKUnit.secondUnit(with: .milli)
        let grouped = Dictionary(grouping: rr) { $0.ts / 300 }
        return grouped.compactMap { bucket, rows in
            guard rows.count >= 5, let sdnn = sdnn(rows.map { Double($0.rrMs) }) else { return nil }
            let startTs = bucket * 300
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: sdnn),
                start: Date(timeIntervalSince1970: TimeInterval(startTs)),
                end: Date(timeIntervalSince1970: TimeInterval(startTs + 300)),
                metadata: syncMetadata("hrv.sdnn.\(startTs)")
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private static func respiratoryRateSamples(from resp: [RespSample]) -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .respiratoryRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let grouped = Dictionary(grouping: resp) { $0.ts / 300 }
        return grouped.compactMap { bucket, rows in
            guard let rate = respiratoryRate(from: rows) else { return nil }
            let startTs = bucket * 300
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: rate),
                start: Date(timeIntervalSince1970: TimeInterval(startTs)),
                end: Date(timeIntervalSince1970: TimeInterval(startTs + 300)),
                metadata: syncMetadata("resp.\(startTs)")
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private static func sleepSamples(hr: [HRSample],
                                     rr: [RRInterval],
                                     resp: [RespSample],
                                     gravity: [GravitySample]) -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let nowTs = Int(Date().timeIntervalSince1970)
        let selectedDayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let summary = IOSWhoopDeviceMetrics.whoopSleepSummary(
            hr: hr,
            rr: rr,
            resp: resp,
            gravity: gravity,
            selectedDayStart: selectedDayStart,
            nowTs: nowTs
        )
        return summary.intervals.compactMap { interval in
            guard interval.end > interval.start else { return nil }
            return HKCategorySample(
                type: type,
                value: healthSleepValue(for: interval.stage),
                start: interval.start,
                end: interval.end,
                metadata: syncMetadata("sleep.\(Int(interval.start.timeIntervalSince1970)).\(Int(interval.end.timeIntervalSince1970)).\(interval.stage)")
            )
        }
    }

    private static func workoutSamples(hr: [HRSample], gravity: [GravitySample]) -> [HKWorkout] {
        let resting = hr.map(\.bpm).sorted().first.map(Double.init)
        let sessions = WorkoutDetector.detect(
            hr: hr,
            gravity: gravity,
            restingHR: resting,
            age: 30,
            profile: UserProfile(age: 30)
        )
        return sessions.map { session in
            let start = Date(timeIntervalSince1970: TimeInterval(session.start))
            let end = Date(timeIntervalSince1970: TimeInterval(session.end))
            let energy = session.caloriesKcal.map {
                HKQuantity(unit: .kilocalorie(), doubleValue: $0)
            }
            return HKWorkout(
                activityType: .other,
                start: start,
                end: end,
                duration: session.durationS,
                totalEnergyBurned: energy,
                totalDistance: nil,
                metadata: syncMetadata("workout.\(session.start).\(session.end)")
            )
        }
    }

    private static func healthSleepValue(for stage: String) -> Int {
        switch stage.lowercased() {
        case "wake": return HKCategoryValueSleepAnalysis.awake.rawValue
        case "deep": return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case "rem": return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        default: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        }
    }

    private static func syncMetadata(_ id: String) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: "noop.whoop.\(id)",
            HKMetadataKeySyncVersion: 1,
            "NOOPSource": "WHOOP",
        ]
    }

    private static func sdnn(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return variance.squareRoot()
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

    nonisolated private static func sleepTotals(from samples: [HKCategorySample]) -> (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]) {
        var inBedIntervals: [IOSSleepInterval] = []
        var rawIntervals: [IOSSleepInterval] = []

        for sample in samples {
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBedIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Core"))
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Awake"))
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Deep"))
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "REM"))
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Core"))
            default:
                break
            }
        }

        let hasAsleepStages = rawIntervals.contains { $0.stage != "Awake" }
        let intervals = normalizedSleepIntervals(hasAsleepStages ? rawIntervals : inBedIntervals)

        var awake = 0.0
        var core = 0.0
        var deep = 0.0
        var rem = 0.0
        for interval in intervals {
            let hours = interval.end.timeIntervalSince(interval.start) / 3600.0
            switch interval.stage {
            case "Awake": awake += hours
            case "Deep": deep += hours
            case "REM": rem += hours
            default: core += hours
            }
        }

        let inBed = mergedDurationHours(inBedIntervals)
        let total = core + deep + rem
        let denominator = hasAsleepStages ? total + awake : max(inBed, total + awake)
        let efficiency = denominator > 0 ? total / denominator : 0
        return (total, efficiency, [
            IOSSleepStageSummary(name: "Core", hours: core),
            IOSSleepStageSummary(name: "Deep", hours: deep),
            IOSSleepStageSummary(name: "REM", hours: rem),
            IOSSleepStageSummary(name: "Awake", hours: awake),
        ].filter { $0.hours > 0.01 }, intervals.sorted { $0.start < $1.start })
    }

    nonisolated private static func normalizedSleepIntervals(_ intervals: [IOSSleepInterval]) -> [IOSSleepInterval] {
        let sorted = intervals
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        let boundaries = Array(Set(sorted.flatMap { [$0.start, $0.end] })).sorted()
        guard boundaries.count >= 2 else { return [] }

        let slices = zip(boundaries, boundaries.dropFirst()).compactMap { start, end -> IOSSleepInterval? in
            guard end > start else { return nil }
            let covering = sorted.filter { $0.start < end && $0.end > start }
            guard let stage = preferredStage(from: covering.map(\.stage)) else { return nil }
            return IOSSleepInterval(start: start, end: end, stage: stage)
        }
        return mergeAdjacentSleepIntervals(slices)
    }

    nonisolated private static func preferredStage(from stages: [String]) -> String? {
        if stages.contains("Awake") { return "Awake" }
        if stages.contains("Deep") { return "Deep" }
        if stages.contains("REM") { return "REM" }
        if stages.contains("Core") { return "Core" }
        return stages.first
    }

    nonisolated private static func mergeAdjacentSleepIntervals(_ intervals: [IOSSleepInterval]) -> [IOSSleepInterval] {
        guard var current = intervals.first else { return [] }
        var merged: [IOSSleepInterval] = []
        for interval in intervals.dropFirst() {
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

    nonisolated private static func mergedDurationHours(_ intervals: [IOSSleepInterval]) -> Double {
        normalizedSleepIntervals(intervals).reduce(0) {
            $0 + $1.end.timeIntervalSince($1.start) / 3600.0
        }
    }

    nonisolated private static func mostRecentSleepCluster(from samples: [HKCategorySample]) -> [HKCategorySample] {
        guard let latestEnd = samples.map(\.endDate).max() else { return [] }
        let clusterStart = latestEnd.addingTimeInterval(-18 * 3600)
        return samples.filter { sample in
            sample.endDate >= clusterStart && sample.startDate <= latestEnd
        }
    }

    private static func sleepScore(hours: Double, efficiency: Double) -> Int? {
        guard hours > 0 else { return nil }
        let durationComponent = min(1.0, hours / 8.0) * 70.0
        let efficiencyComponent = min(1.0, max(0.0, efficiency)) * 30.0
        return Int(min(100.0, durationComponent + efficiencyComponent).rounded())
    }

    enum ExportError: LocalizedError {
        case authorizationDenied
        case saveFailed
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .authorizationDenied: return "Apple Health write access was not granted"
            case .saveFailed: return "Apple Health did not save the exported WHOOP data"
            case .deleteFailed: return "Apple Health did not replace the prior NOOP sleep export"
            }
        }
    }
}
