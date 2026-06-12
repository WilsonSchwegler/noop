import Foundation
import CoreLocation
import HealthKit
import StrandAnalytics
import TrackerProtocol
import TrackerStore

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
    private static let cachedHealthHRVByDayKey = "warbfit.health.cachedHRVSDNNByDay.v1"
    private static let manualSleepWindowsByDayKey = "warbfit.health.manualSleepWindowsByDay.v1"

    @Published var isAvailable = HKHealthStore.isHealthDataAvailable()
    @Published var isAuthorized = false
    @Published var status = "Health access not requested"
    @Published var sleepHours = 0.0
    @Published var sleepScore: Int?
    @Published var sleepEfficiency = 0.0
    @Published var sleepStages: [IOSSleepStageSummary] = []
    @Published var sleepIntervals: [IOSSleepInterval] = []
    @Published var dailyHRSamples: [IOSMetricHRSample] = []
    @Published var dailyStrain: Double?
    @Published var recoveryScore: Double?
    @Published var recoveryStatus = "Waiting for Apple Health readiness inputs"
    @Published var restingHR: Int?
    @Published var exertionRestingHR: Double?
    @Published var hrvSDNN: Double?
    @Published var respiratoryRate: Double?
    @Published var exportStatus = "Fitness tracker export not run"
    @Published var isExporting = false
    @Published var importStatus = "Apple Health import not run"
    @Published var isImporting = false

    private let store = HKHealthStore()
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

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

    func refresh(for date: Date = Date(), force: Bool = false) {
        guard isAvailable else {
            status = "HealthKit is not available on this device"
            return
        }
        guard refreshTask == nil || force else { return }
        if force {
            refreshTask?.cancel()
            refreshTask = nil
        }
        refreshGeneration += 1
        let generation = refreshGeneration

        refreshTask = Task { @MainActor in
            defer {
                if generation == refreshGeneration {
                    refreshTask = nil
                }
            }
            do {
                try await requestReadAuthorization()
                let metrics = try await healthMetrics(for: date)
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                apply(metrics)
                isAuthorized = true
                status = metrics.sleepHours > 0
                    ? "Health metrics loaded"
                    : "No Apple Health sleep records readable by WarbFit"
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                fetchSleep(for: date)
                status = "Health metrics read failed: \(error.localizedDescription)"
            }
        }
    }

    func setSleepWindow(start: Date, end: Date, for date: Date) async {
        guard end.timeIntervalSince(start) >= 30 * 60 else {
            recoveryStatus = "Sleep window must be at least 30 minutes"
            return
        }
        Self.saveManualSleepWindow(start: start, end: end, for: date, calendar: Calendar.current)
        refresh(for: date, force: true)
    }

    func resetSleepWindow(for date: Date) async {
        Self.clearManualSleepWindow(for: date, calendar: Calendar.current)
        refresh(for: date, force: true)
    }

    func importRecentWorkouts(into recorder: IOSWorkoutRecorder,
                              days: Int = 30,
                              since earliestStart: Date? = nil) {
        guard isAvailable else {
            importStatus = "HealthKit is not available on this device"
            return
        }
        guard !isImporting else { return }
        isImporting = true
        importStatus = "Requesting Apple Health access"

        Task { @MainActor in
            do {
                try await requestReadAuthorization()
                importStatus = "Reading Apple Health workouts"
                let workouts = try await healthWorkouts(days: days, since: earliestStart)
                let imported = recorder.importHealthWorkouts(workouts)
                isAuthorized = true
                importStatus = imported == 0
                    ? "Apple Health workouts are up to date"
                    : "Imported \(imported) Apple Health workout\(imported == 1 ? "" : "s")"
            } catch {
                importStatus = "Health import failed: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    func exportTrackerData(store _: TrackerStore, deviceId _: String) {
        exportStatus = "Apple Health export is disabled for Bluetooth tracker data."
    }

    private func fetchSleep(for date: Date = Date()) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let dayStart = Calendar.current.startOfDay(for: date)
        let start = Calendar.current.date(byAdding: .hour, value: -18, to: dayStart) ?? dayStart
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            let categorySamples = ((samples as? [HKCategorySample]) ?? []).filter { !Self.isWarbFitExport($0) }
            let selectedSamples = Self.mainSleepCluster(from: categorySamples, dayStart: dayStart, dayEnd: end)
            let totals = Self.sleepTotals(from: selectedSamples)
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.applySleepTotals(totals)
                    self.applySleepOnlyRecovery(totals, reason: "Provisional readiness from Apple Health sleep; metrics read failed")
                    self.status = "Health sleep read failed: \(error.localizedDescription)"
                } else if totals.total > 0 {
                    self.applySleepTotals(totals)
                    self.applySleepOnlyRecovery(totals, reason: "Provisional readiness from Apple Health sleep; waiting for HRV/RHR")
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

    private func applySleepOnlyRecovery(_ totals: (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]),
                                        reason: String) {
        guard let sleepPerf = Self.sleepPerformance(hours: totals.total, efficiency: totals.efficiency, stages: totals.stages),
              let score = Self.recoveryWithoutHRV(
                rhr: nil,
                resp: nil,
                rhrBaseline: nil,
                respBaseline: nil,
                sleepPerf: sleepPerf
              ) else {
            recoveryScore = nil
            recoveryStatus = "Waiting for Apple Health readiness inputs"
            return
        }
        recoveryScore = score
        recoveryStatus = reason
        restingHR = nil
        hrvSDNN = nil
        respiratoryRate = nil
    }

    private struct HealthMetrics {
        let sleepHours: Double
        let sleepEfficiency: Double
        let sleepStages: [IOSSleepStageSummary]
        let sleepIntervals: [IOSSleepInterval]
        let dailyHRSamples: [IOSMetricHRSample]
        let dailyStrain: Double?
        let recoveryScore: Double?
        let recoveryStatus: String
        let restingHR: Int?
        let exertionRestingHR: Double?
        let hrvSDNN: Double?
        let respiratoryRate: Double?
    }

    private struct StoredManualSleepWindow: Codable {
        let start: TimeInterval
        let end: TimeInterval
    }

    private func apply(_ metrics: HealthMetrics) {
        sleepHours = metrics.sleepHours
        sleepEfficiency = metrics.sleepEfficiency
        sleepScore = Self.sleepScore(hours: metrics.sleepHours, efficiency: metrics.sleepEfficiency)
        sleepStages = metrics.sleepStages
        sleepIntervals = metrics.sleepIntervals
        dailyHRSamples = metrics.dailyHRSamples
        dailyStrain = metrics.dailyStrain
        recoveryScore = metrics.recoveryScore
        recoveryStatus = metrics.recoveryStatus
        restingHR = metrics.restingHR
        exertionRestingHR = metrics.exertionRestingHR
        hrvSDNN = metrics.hrvSDNN
        respiratoryRate = metrics.respiratoryRate
    }

    private func healthMetrics(for date: Date) async throws -> HealthMetrics {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let boundedEnd = now < dayEnd ? now : dayEnd
        let sleepStart = calendar.date(byAdding: .hour, value: -18, to: dayStart) ?? dayStart.addingTimeInterval(-18 * 3600)
        let historyStart = calendar.date(byAdding: .day, value: -31, to: sleepStart) ?? sleepStart.addingTimeInterval(-31 * 86_400)

        let currentSleepSamples = Self.mainSleepCluster(
            from: try await querySleepSamples(start: sleepStart, end: dayEnd),
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        let rawSleepTotals = Self.sleepTotals(from: currentSleepSamples)
        let manualSleepWindow = Self.manualSleepWindow(for: date, calendar: calendar)
        let sleepTotals = Self.adjustedSleepTotals(rawSleepTotals, manualWindow: manualSleepWindow)
        let historySleepSamples = try await querySleepSamples(start: historyStart, end: dayEnd)
        let hrSamples = await optionalQuantitySamples(.heartRate, start: historyStart, end: boundedEnd)
        let hrvSamples = await optionalQuantitySamples(.heartRateVariabilitySDNN, start: historyStart, end: boundedEnd)
        let respSamples = await optionalQuantitySamples(.respiratoryRate, start: historyStart, end: boundedEnd)
        let restingSamples = await optionalQuantitySamples(.restingHeartRate, start: historyStart, end: boundedEnd)

        let dailyHR = Self.heartRateRows(from: hrSamples, start: dayStart, end: boundedEnd)
        let profile = IOSUserBodyProfile.current
        let recovery = Self.healthRecovery(
            date: date,
            sleepTotals: sleepTotals,
            historySleepSamples: historySleepSamples,
            hrSamples: hrSamples,
            hrvSamples: hrvSamples,
            respSamples: respSamples,
            restingSamples: restingSamples,
            sleepWindowAdjusted: manualSleepWindow != nil,
            calendar: calendar
        )
        let exertionRestingHRBaseline = Self.healthExertionRestingHRBaseline(
            date: date,
            historySleepSamples: historySleepSamples,
            hrSamples: hrSamples,
            restingSamples: restingSamples,
            calendar: calendar
        )
        IOSStrainEstimator.saveExertionRestingHRBaseline(exertionRestingHRBaseline, for: .appleWatch)
        let exertionRestingHR = IOSStrainEstimator.exertionRestingHR(
            baseline: exertionRestingHRBaseline,
            recentRestingHR: recovery.restingHR.map(Double.init),
            samples: dailyHR.map { HRSample(ts: $0.ts, bpm: $0.bpm) },
            source: .appleWatch
        )
        let dailyStrain = IOSStrainEstimator.awakeDayStrain(
            metricSamples: dailyHR,
            maxHR: profile.estimatedMaxHR,
            restingHR: exertionRestingHR,
            physiologySex: profile.physiologySex.analyticsValue
        )

        return HealthMetrics(
            sleepHours: sleepTotals.total,
            sleepEfficiency: sleepTotals.efficiency,
            sleepStages: sleepTotals.stages,
            sleepIntervals: sleepTotals.intervals,
            dailyHRSamples: dailyHR,
            dailyStrain: dailyStrain,
            recoveryScore: recovery.score,
            recoveryStatus: recovery.status,
            restingHR: recovery.restingHR,
            exertionRestingHR: exertionRestingHR,
            hrvSDNN: recovery.hrvSDNN,
            respiratoryRate: recovery.respiratoryRate
        )
    }

    private func fetchMostRecentSleepFallback(type: HKCategoryType, before end: Date) {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end.addingTimeInterval(-7 * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            let categorySamples = ((samples as? [HKCategorySample]) ?? []).filter { !Self.isWarbFitExport($0) }
            let recentSamples = Self.mostRecentSleepCluster(from: categorySamples)
            let totals = Self.sleepTotals(from: recentSamples)
            Task { @MainActor in
                guard let self else { return }
                self.applySleepTotals(totals)
                if totals.total > 0 {
                    self.applySleepOnlyRecovery(totals, reason: "Provisional readiness from latest Apple Health sleep; waiting for HRV/RHR")
                }
                if let error {
                    self.status = "Health sleep fallback failed: \(error.localizedDescription)"
                } else if totals.total > 0 {
                    self.isAuthorized = true
                    self.status = "Loaded latest Health sleep from last 7 days (\(recentSamples.count) records)"
                } else if categorySamples.isEmpty {
                    self.status = "No Apple Health sleep records readable by WarbFit"
                } else {
                    self.status = "Health returned \(categorySamples.count) sleep records, but no asleep intervals"
                }
            }
        }
        store.execute(query)
    }

    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let resting = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(resting) }
        if let resp = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { types.insert(resp) }
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        return types
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

    private func requestReadAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: Self.readTypes) { success, error in
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

    private func querySleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let categorySamples = ((samples as? [HKCategorySample]) ?? []).filter { !Self.isWarbFitExport($0) }
                    continuation.resume(returning: categorySamples)
                }
            }
            store.execute(query)
        }
    }

    private func quantitySamples(_ identifier: HKQuantityTypeIdentifier,
                                 start: Date,
                                 end: Date) async throws -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier), end > start else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let quantitySamples = ((samples as? [HKQuantitySample]) ?? []).filter { !Self.isWarbFitExport($0) }
                    continuation.resume(returning: quantitySamples)
                }
            }
            store.execute(query)
        }
    }

    private func optionalQuantitySamples(_ identifier: HKQuantityTypeIdentifier,
                                         start: Date,
                                         end: Date) async -> [HKQuantitySample] {
        (try? await quantitySamples(identifier, start: start, end: end)) ?? []
    }

    private func healthWorkouts(days: Int, since earliestStart: Date? = nil) async throws -> [IOSLoggedWorkout] {
        let end = Date()
        let lookbackStart = Calendar.current.date(byAdding: .day, value: -max(1, days), to: end) ?? end.addingTimeInterval(-Double(max(1, days)) * 86_400)
        let start = earliestStart.map { max(lookbackStart, $0) } ?? lookbackStart
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let workouts = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 50, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }

        var logged: [IOSLoggedWorkout] = []
        for workout in workouts {
            let type = Self.workoutType(for: workout)
            let hr = try await heartRateSamples(for: workout)
            let routePoints = await optionalRoutePoints(for: workout)
            let profile = IOSUserBodyProfile.current
            let strain = IOSStrainEstimator.strain(
                hr: hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) },
                workoutTypeId: type.id,
                maxHR: profile.estimatedMaxHR,
                restingHR: IOSStrainEstimator.cachedExertionRestingHR(for: .appleWatch),
                physiologySex: profile.physiologySex.analyticsValue
            )
            logged.append(IOSLoggedWorkout(
                id: workout.uuid,
                typeId: type.id,
                typeName: type.name,
                startedAt: workout.startDate,
                endedAt: workout.endDate,
                notes: "",
                hrSamples: hr,
                strain: strain,
                routePoints: routePoints,
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                source: .appleHealth
            ))
        }
        return logged
    }

    private func heartRateSamples(for workout: HKWorkout) async throws -> [IOSWorkoutHRSample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { sample in
            let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
            guard bpm >= 30, bpm <= 230 else { return nil }
            return IOSWorkoutHRSample(ts: Int(sample.startDate.timeIntervalSince1970), bpm: bpm)
        }
    }

    private func optionalRoutePoints(for workout: HKWorkout) async -> [IOSRoutePoint] {
        (try? await routePoints(for: workout)) ?? []
    }

    private func routePoints(for workout: HKWorkout) async throws -> [IOSRoutePoint] {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routes = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let query = HKSampleQuery(sampleType: routeType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
                }
            }
            store.execute(query)
        }
        var allLocations: [CLLocation] = []
        for route in routes {
            allLocations.append(contentsOf: try await locations(for: route))
        }
        return Self.routePoints(from: allLocations)
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLLocation], Error>) in
            var rows: [CLLocation] = []
            var didResume = false
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                rows.append(contentsOf: locations ?? [])
                if done {
                    didResume = true
                    continuation.resume(returning: rows)
                }
            }
            store.execute(query)
        }
    }

    private static func workoutType(for workout: HKWorkout) -> IOSWorkoutType {
        switch workout.workoutActivityType {
        case .running:
            let indoorValue = workout.metadata?[HKMetadataKeyIndoorWorkout]
            let isIndoor = (indoorValue as? Bool) ?? (indoorValue as? NSNumber)?.boolValue ?? false
            if isIndoor {
                return IOSWorkoutType(id: "treadmill", name: "Treadmill", icon: "figure.run")
            }
            return IOSWorkoutType(id: "run", name: "Run", icon: "figure.run")
        case .hiking:
            return IOSWorkoutType(id: "hiking", name: "Hiking", icon: "figure.hiking")
        case .swimming:
            return IOSWorkoutType(id: "swim", name: "Swimming", icon: "figure.pool.swim")
        case .walking:
            return IOSWorkoutType(id: "walking", name: "Walk", icon: "figure.walk")
        case .cycling:
            return IOSWorkoutType(id: "cycling", name: "Cycling", icon: "bicycle")
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return IOSWorkoutType(id: "strength", name: "Strength Training", icon: "dumbbell.fill")
        case .stairClimbing, .stairs:
            return IOSWorkoutType(id: "stairmaster", name: "Stairs", icon: "figure.stairs")
        default:
            return IOSWorkoutType(id: "workout", name: workout.workoutActivityType.name, icon: "figure.mixed.cardio")
        }
    }

    private static func routePoints(from locations: [CLLocation]) -> [IOSRoutePoint] {
        let sorted = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 }
            .sorted { $0.timestamp < $1.timestamp }
        var points: [IOSRoutePoint] = []
        for location in sorted {
            if let last = points.last {
                let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
                guard previous.distance(from: location) >= 8 else { continue }
            }
            points.append(IOSRoutePoint(
                ts: Int(location.timestamp.timeIntervalSince1970),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
            ))
        }
        return simplifiedRoute(points, maxPoints: 500)
    }

    private static func simplifiedRoute(_ points: [IOSRoutePoint], maxPoints: Int) -> [IOSRoutePoint] {
        guard points.count > maxPoints, maxPoints > 1 else { return points }
        let stride = max(1, points.count / maxPoints)
        var reduced = points.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) ? point : nil
        }
        if reduced.last != points.last, let last = points.last {
            reduced.append(last)
        }
        return reduced
    }

    private static func healthRecovery(date: Date,
                                       sleepTotals: (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]),
                                       historySleepSamples: [HKCategorySample],
                                       hrSamples: [HKQuantitySample],
                                       hrvSamples: [HKQuantitySample],
                                       respSamples: [HKQuantitySample],
                                       restingSamples: [HKQuantitySample],
                                       sleepWindowAdjusted: Bool,
                                       calendar: Calendar) -> (score: Double?, status: String, restingHR: Int?, hrvSDNN: Double?, respiratoryRate: Double?) {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let currentSegments = asleepSegments(from: sleepTotals.intervals)
        let currentRHR = restingHeartRate(from: restingSamples, start: dayStart, end: dayEnd)
            ?? restingHeartRate(from: hrSamples, segments: currentSegments)
        let currentHRV = healthHRV(
            from: hrvSamples,
            day: dayStart,
            dayEnd: dayEnd,
            sleepSegments: currentSegments,
            calendar: calendar
        )
        let currentResp = averageQuantity(respSamples, unit: HKUnit.count().unitDivided(by: .minute()), segments: currentSegments)
        let sleepPerf = sleepPerformance(hours: sleepTotals.total, efficiency: sleepTotals.efficiency, stages: sleepTotals.stages)

        var hrvNights: [Double?] = []
        var rhrNights: [Double?] = []
        var respNights: [Double?] = []
        for offset in stride(from: 30, through: 1, by: -1) {
            guard let baselineDay = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
            let baselineDayEnd = calendar.date(byAdding: .day, value: 1, to: baselineDay) ?? baselineDay.addingTimeInterval(86_400)
            let baselineSleepStart = calendar.date(byAdding: .hour, value: -18, to: baselineDay) ?? baselineDay.addingTimeInterval(-18 * 3600)
            let baselineSleepSamples = historySleepSamples.filter { $0.startDate < baselineDayEnd && $0.endDate > baselineSleepStart }
            let baselineSleepCluster = Self.mainSleepCluster(
                from: baselineSleepSamples,
                dayStart: baselineDay,
                dayEnd: baselineDayEnd
            )
            let rawBaselineSleep = Self.sleepTotals(from: baselineSleepCluster)
            let baselineSleep = Self.adjustedSleepTotals(
                rawBaselineSleep,
                manualWindow: Self.manualSleepWindow(for: baselineDay, calendar: calendar)
            )
            let segments = asleepSegments(from: baselineSleep.intervals)
            hrvNights.append(
                healthHRV(
                    from: hrvSamples,
                    day: baselineDay,
                    dayEnd: baselineDayEnd,
                    sleepSegments: segments,
                    calendar: calendar
                )
            )
            rhrNights.append(
                restingHeartRate(from: restingSamples, start: baselineDay, end: baselineDayEnd).map(Double.init)
                    ?? restingHeartRate(from: hrSamples, segments: segments).map(Double.init)
            )
            respNights.append(averageQuantity(respSamples, unit: HKUnit.count().unitDivided(by: .minute()), segments: segments))
        }

        guard sleepTotals.total > 0 else {
            return (nil, "Waiting for Apple Health sleep stages", currentRHR, currentHRV, currentResp)
        }

        let sleepStatusText = sleepWindowAdjusted ? "adjusted Apple Health sleep window" : "Apple Health sleep"
        let hrvBaseline = Baselines.foldHistory(hrvNights, cfg: Baselines.hrvCfg)
        let rhrBaseline = Baselines.foldHistory(rhrNights, cfg: Baselines.restingHRCfg)
        let respBaseline = Baselines.foldHistory(respNights, cfg: Baselines.respCfg)

        guard let currentRHR else {
            let provisional = recoveryWithoutHRV(
                rhr: nil,
                resp: currentResp,
                rhrBaseline: nil,
                respBaseline: respBaseline,
                sleepPerf: sleepPerf
            )
            return (
                provisional,
                provisional == nil
                    ? "Waiting for Apple Health resting heart rate"
                    : "Provisional readiness from \(sleepStatusText); waiting for overnight resting HR",
                currentRHR,
                currentHRV,
                currentResp
            )
        }

        guard let currentHRV else {
            let provisional = recoveryWithoutHRV(
                rhr: Double(currentRHR),
                resp: currentResp,
                rhrBaseline: rhrBaseline,
                respBaseline: respBaseline,
                sleepPerf: sleepPerf
            )
            return (
                provisional,
                provisional == nil
                    ? "Waiting for Apple Health HRV"
                    : "Provisional readiness from \(sleepStatusText) without HRV",
                currentRHR,
                nil,
                currentResp
            )
        }

        let score = RecoveryScorer.recovery(
            hrv: currentHRV,
            rhr: Double(currentRHR),
            resp: currentResp,
            hrvBaseline: hrvBaseline,
            rhrBaseline: rhrBaseline,
            respBaseline: respBaseline,
            sleepPerf: sleepPerf
        )

        if let score {
            let respText = currentResp == nil ? "" : "/respiration"
            return (
                score,
                "WarbFit readiness from \(sleepStatusText), HRV/RHR\(respText)",
                currentRHR,
                currentHRV,
                currentResp
            )
        }

        let provisional = provisionalRecoveryScore(sleepPerf: sleepPerf)
        return (
            provisional,
            "Provisional readiness while Apple Health HRV baseline calibrates \(hrvBaseline.nValid)/\(Baselines.minNightsSeed) nights",
            currentRHR,
            currentHRV,
            currentResp
        )
    }

    private static func healthExertionRestingHRBaseline(date: Date,
                                                        historySleepSamples: [HKCategorySample],
                                                        hrSamples: [HKQuantitySample],
                                                        restingSamples: [HKQuantitySample],
                                                        calendar: Calendar) -> Double? {
        let dayStart = calendar.startOfDay(for: date)
        var rhrNights: [Double?] = []
        for offset in stride(from: 30, through: 1, by: -1) {
            guard let baselineDay = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
            let baselineDayEnd = calendar.date(byAdding: .day, value: 1, to: baselineDay) ?? baselineDay.addingTimeInterval(86_400)
            let baselineSleepStart = calendar.date(byAdding: .hour, value: -18, to: baselineDay) ?? baselineDay.addingTimeInterval(-18 * 3600)
            let baselineSleepSamples = historySleepSamples.filter { $0.startDate < baselineDayEnd && $0.endDate > baselineSleepStart }
            let baselineSleepCluster = Self.mainSleepCluster(
                from: baselineSleepSamples,
                dayStart: baselineDay,
                dayEnd: baselineDayEnd
            )
            let rawBaselineSleep = Self.sleepTotals(from: baselineSleepCluster)
            let baselineSleep = Self.adjustedSleepTotals(
                rawBaselineSleep,
                manualWindow: Self.manualSleepWindow(for: baselineDay, calendar: calendar)
            )
            let segments = asleepSegments(from: baselineSleep.intervals)
            let sleepDerived = restingHeartRate(from: hrSamples, segments: segments).map(Double.init)
            let healthDerived = restingHeartRate(from: restingSamples, start: baselineDay, end: baselineDayEnd).map(Double.init)
            rhrNights.append(sleepDerived ?? healthDerived)
        }

        let baseline = Baselines.foldHistory(rhrNights, cfg: Baselines.restingHRCfg)
        return baseline.usable ? baseline.baseline : nil
    }

    private static func heartRateRows(from samples: [HKQuantitySample],
                                      start: Date,
                                      end: Date) -> [IOSMetricHRSample] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        var byMinute: [Int: [Int]] = [:]
        for sample in samples where sample.startDate >= start && sample.startDate <= end {
            let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
            guard bpm >= 30, bpm <= 230 else { continue }
            byMinute[Int(sample.startDate.timeIntervalSince1970) / 60, default: []].append(bpm)
        }
        return byMinute.keys.sorted().enumerated().map { index, minute in
            let values = byMinute[minute] ?? []
            let avg = values.isEmpty ? 0 : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            return IOSMetricHRSample(id: index, ts: minute * 60, bpm: avg)
        }
    }

    private static func averageQuantity(_ samples: [HKQuantitySample],
                                        unit: HKUnit,
                                        segments: [DateInterval]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let values = samples
            .filter { sample in segments.contains { $0.intersects(DateInterval(start: sample.startDate, end: sample.endDate)) } }
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func averageQuantity(_ samples: [HKQuantitySample],
                                        unit: HKUnit,
                                        start: Date,
                                        end: Date) -> Double? {
        let values = samples
            .filter { $0.startDate >= start && $0.startDate <= end }
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func healthHRV(from samples: [HKQuantitySample],
                                  day: Date,
                                  dayEnd: Date,
                                  sleepSegments: [DateInterval],
                                  calendar: Calendar) -> Double? {
        let unit = HKUnit.secondUnit(with: .milli)
        let sleepValue = averageQuantity(samples, unit: unit, segments: sleepSegments)
        let overnightStart = calendar.date(byAdding: .hour, value: -18, to: day) ?? day.addingTimeInterval(-18 * 3600)
        let overnightEnd = minDate(dayEnd, Date())
        let overnightValue = averageQuantity(samples, unit: unit, start: overnightStart, end: overnightEnd)
        let dayValue = averageQuantity(samples, unit: unit, start: day, end: overnightEnd)
        let cached = cachedHealthHRV(for: day, calendar: calendar)
        let value = sleepValue ?? overnightValue ?? dayValue ?? cached
        if let fresh = sleepValue ?? overnightValue ?? dayValue {
            cacheHealthHRV(fresh, for: day, calendar: calendar)
        }
        return value
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs < rhs ? lhs : rhs
    }

    private static func recoveryWithoutHRV(rhr: Double?,
                                           resp: Double?,
                                           rhrBaseline: BaselineState?,
                                           respBaseline: BaselineState?,
                                           sleepPerf: Double?) -> Double? {
        RecoveryScorer.recovery(
            hrv: 0,
            rhr: rhr ?? 0,
            resp: resp,
            hrvBaseline: nil,
            rhrBaseline: rhr == nil ? nil : rhrBaseline.map(RecoveryScorer.DriverBaseline.init),
            respBaseline: respBaseline.map(RecoveryScorer.DriverBaseline.init),
            sleepPerf: sleepPerf,
            hrvBaselineUsable: true
        ) ?? provisionalRecoveryScore(sleepPerf: sleepPerf)
    }

    private static func cacheHealthHRV(_ value: Double, for date: Date, calendar: Calendar) {
        guard value.isFinite, value > 0 else { return }
        var cache = UserDefaults.standard.dictionary(forKey: cachedHealthHRVByDayKey) as? [String: Double] ?? [:]
        cache[healthCacheDayKey(for: date, calendar: calendar)] = value
        if cache.count > 90 {
            let keysToDrop = cache.keys.sorted().prefix(cache.count - 90)
            for key in keysToDrop { cache.removeValue(forKey: key) }
        }
        UserDefaults.standard.set(cache, forKey: cachedHealthHRVByDayKey)
    }

    private static func cachedHealthHRV(for date: Date, calendar: Calendar) -> Double? {
        let cache = UserDefaults.standard.dictionary(forKey: cachedHealthHRVByDayKey) as? [String: Double] ?? [:]
        let value = cache[healthCacheDayKey(for: date, calendar: calendar)]
        return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func manualSleepWindow(for date: Date, calendar: Calendar) -> DateInterval? {
        let key = healthCacheDayKey(for: date, calendar: calendar)
        guard let stored = storedManualSleepWindows()[key],
              stored.end - stored.start >= 30 * 60 else { return nil }
        return DateInterval(
            start: Date(timeIntervalSince1970: stored.start),
            end: Date(timeIntervalSince1970: stored.end)
        )
    }

    private static func saveManualSleepWindow(start: Date, end: Date, for date: Date, calendar: Calendar) {
        guard end.timeIntervalSince(start) >= 30 * 60 else { return }
        var windows = storedManualSleepWindows()
        windows[healthCacheDayKey(for: date, calendar: calendar)] = StoredManualSleepWindow(
            start: start.timeIntervalSince1970,
            end: end.timeIntervalSince1970
        )
        saveManualSleepWindows(windows)
    }

    private static func clearManualSleepWindow(for date: Date, calendar: Calendar) {
        var windows = storedManualSleepWindows()
        windows.removeValue(forKey: healthCacheDayKey(for: date, calendar: calendar))
        saveManualSleepWindows(windows)
    }

    private static func storedManualSleepWindows() -> [String: StoredManualSleepWindow] {
        guard let data = UserDefaults.standard.data(forKey: manualSleepWindowsByDayKey),
              let windows = try? JSONDecoder().decode([String: StoredManualSleepWindow].self, from: data) else {
            return [:]
        }
        return windows
    }

    private static func saveManualSleepWindows(_ windows: [String: StoredManualSleepWindow]) {
        var trimmed = windows
        if trimmed.count > 120 {
            let keysToDrop = trimmed.keys.sorted().prefix(trimmed.count - 120)
            for key in keysToDrop { trimmed.removeValue(forKey: key) }
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: manualSleepWindowsByDayKey)
    }

    private static func healthCacheDayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func restingHeartRate(from samples: [HKQuantitySample], start: Date, end: Date) -> Int? {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let values = samples
            .filter { $0.startDate >= start && $0.startDate <= end }
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { $0 >= 30 && $0 <= 220 }
        guard !values.isEmpty else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }

    private static func restingHeartRate(from samples: [HKQuantitySample],
                                         segments: [DateInterval]) -> Int? {
        guard !segments.isEmpty else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let rows = samples.compactMap { sample -> HRSample? in
            let interval = DateInterval(start: sample.startDate, end: sample.endDate)
            guard segments.contains(where: { $0.intersects(interval) }) else { return nil }
            let bpm = Int(sample.quantity.doubleValue(for: unit).rounded())
            guard bpm >= 30, bpm <= 230 else { return nil }
            return HRSample(ts: Int(sample.startDate.timeIntervalSince1970), bpm: bpm)
        }
        guard let start = segments.map(\.start).min(),
              let end = segments.map(\.end).max() else { return nil }
        return RecoveryScorer.restingHR(
            rows,
            start: Int(start.timeIntervalSince1970),
            end: Int(end.timeIntervalSince1970)
        )
    }

    private static func asleepSegments(from intervals: [IOSSleepInterval]) -> [DateInterval] {
        intervals.compactMap { interval in
            guard interval.stage != "Awake", interval.end > interval.start else { return nil }
            return DateInterval(start: interval.start, end: interval.end)
        }
    }

    private static func sleepPerformance(hours: Double,
                                         efficiency: Double,
                                         stages: [IOSSleepStageSummary]) -> Double? {
        guard hours > 0 else { return nil }
        let duration = min(1.0, hours / 8.0)
        let deep = stages.first { $0.name == "Deep" }?.hours ?? 0
        let rem = stages.first { $0.name == "REM" }?.hours ?? 0
        let restorative = min(1.0, ((deep + rem) / max(hours, 0.1)) / 0.35)
        var weighted = duration * 0.55 + restorative * 0.20
        var weight = 0.75
        if efficiency > 0 {
            weighted += min(1.0, max(0.0, efficiency) / 0.85) * 0.25
            weight += 0.25
        }
        return max(0.0, min(1.0, weighted / max(weight, 0.1)))
    }

    private static func provisionalRecoveryScore(sleepPerf: Double?) -> Double? {
        guard let sleepPerf else { return nil }
        return max(20.0, min(90.0, 25.0 + sleepPerf * 65.0))
    }

    nonisolated private static func isWarbFitExport(_ sample: HKSample) -> Bool {
        let source = sample.metadata?["WarbFitSource"] as? String
        let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
        return source == "fitness tracker" || syncID?.hasPrefix("warbfit.tracker.") == true
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

    private func deletePriorWarbFitSleepSamples(overlapping window: DateInterval) async throws {
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
                let warbfitSleep = ((samples as? [HKCategorySample]) ?? []).filter { sample in
                    let source = sample.metadata?["WarbFitSource"] as? String
                    let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                    return source == "fitness tracker" && syncID?.hasPrefix("warbfit.tracker.sleep.") == true
                }
                continuation.resume(returning: warbfitSleep)
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

    private static func buildHealthObjects(from store: TrackerStore, deviceId: String) async throws
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
        let summary = IOSTrackerDeviceMetrics.trackerSleepSummary(
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
        let resting = IOSStrainEstimator.cachedExertionRestingHR(for: .tracker)
            ?? IOSStrainEstimator.exertionRestingHR(samples: hr, source: .tracker)
        let profile = IOSUserBodyProfile.current
        let sessions = WorkoutDetector.detect(
            hr: hr,
            gravity: gravity,
            restingHR: resting,
            age: profile.ageForHRMax,
            profile: profile.analyticsProfile
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
            HKMetadataKeySyncIdentifier: "warbfit.tracker.\(id)",
            HKMetadataKeySyncVersion: 1,
            "WarbFitSource": "fitness tracker",
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
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Core"))
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                rawIntervals.append(IOSSleepInterval(start: sample.startDate, end: sample.endDate, stage: "Unstaged"))
            default:
                break
            }
        }

        let intervals = normalizedSleepIntervals(rawIntervals)

        let inBed = mergedDurationHours(inBedIntervals)
        return sleepTotals(from: intervals.sorted { $0.start < $1.start }, inBedHours: inBed)
    }

    nonisolated private static func sleepTotals(from intervals: [IOSSleepInterval],
                                                inBedHours: Double = 0) -> (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]) {
        let normalized = normalizedSleepIntervals(intervals)
        var awake = 0.0
        var core = 0.0
        var deep = 0.0
        var rem = 0.0
        var unstaged = 0.0
        for interval in normalized {
            let hours = interval.end.timeIntervalSince(interval.start) / 3600.0
            switch interval.stage {
            case "Awake": awake += hours
            case "Deep": deep += hours
            case "REM": rem += hours
            case "Unstaged": unstaged += hours
            default: core += hours
            }
        }

        let total = core + deep + rem + unstaged
        let observedWindow = total + awake
        let denominator = inBedHours > 0 ? max(inBedHours, observedWindow) : observedWindow
        let efficiency = denominator > 0 ? total / denominator : 0
        return (total, efficiency, [
            IOSSleepStageSummary(name: "Core", hours: core),
            IOSSleepStageSummary(name: "Deep", hours: deep),
            IOSSleepStageSummary(name: "REM", hours: rem),
            IOSSleepStageSummary(name: "Unstaged", hours: unstaged),
            IOSSleepStageSummary(name: "Awake", hours: awake),
        ].filter { $0.hours > 0.01 }, normalized.sorted { $0.start < $1.start })
    }

    private static func adjustedSleepTotals(
        _ totals: (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]),
        manualWindow: DateInterval?
    ) -> (total: Double, efficiency: Double, stages: [IOSSleepStageSummary], intervals: [IOSSleepInterval]) {
        guard let manualWindow, manualWindow.duration >= 30 * 60 else { return totals }
        let cropped = totals.intervals.compactMap { interval -> IOSSleepInterval? in
            let start = maxDate(interval.start, manualWindow.start)
            let end = minDate(interval.end, manualWindow.end)
            guard end > start else { return nil }
            return IOSSleepInterval(start: start, end: end, stage: interval.stage)
        }
        let withManualGaps = fillUnstagedSleepGaps(cropped, in: manualWindow)
        return sleepTotals(from: withManualGaps, inBedHours: manualWindow.duration / 3600.0)
    }

    private static func fillUnstagedSleepGaps(_ intervals: [IOSSleepInterval],
                                              in window: DateInterval) -> [IOSSleepInterval] {
        let ordered = intervals
            .filter { $0.end > $0.start && $0.end > window.start && $0.start < window.end }
            .sorted { $0.start < $1.start }
        var filled: [IOSSleepInterval] = []
        var cursor = window.start
        for interval in ordered {
            let start = maxDate(interval.start, window.start)
            let end = minDate(interval.end, window.end)
            guard end > start else { continue }
            if start > cursor {
                filled.append(IOSSleepInterval(start: cursor, end: start, stage: "Unstaged"))
            }
            filled.append(IOSSleepInterval(start: start, end: end, stage: interval.stage))
            cursor = maxDate(cursor, end)
        }
        if cursor < window.end {
            filled.append(IOSSleepInterval(start: cursor, end: window.end, stage: "Unstaged"))
        }
        return filled
    }

    nonisolated private static func mainSleepCluster(from samples: [HKCategorySample],
                                                     dayStart: Date,
                                                     dayEnd: Date) -> [HKCategorySample] {
        let sorted = samples
            .filter { isSleepAnalysisValue($0.value) && $0.endDate > $0.startDate }
            .sorted { $0.startDate < $1.startDate }
        guard !sorted.isEmpty else { return [] }

        let maxGap: TimeInterval = 90 * 60
        var clusters: [[HKCategorySample]] = []
        var current: [HKCategorySample] = []
        var currentEnd: Date?
        for sample in sorted {
            if let end = currentEnd,
               sample.startDate.timeIntervalSince(end) > maxGap,
               !current.isEmpty {
                clusters.append(current)
                current = [sample]
                currentEnd = sample.endDate
            } else {
                current.append(sample)
                currentEnd = maxDate(currentEnd ?? sample.endDate, sample.endDate)
            }
        }
        if !current.isEmpty { clusters.append(current) }

        struct Candidate {
            let samples: [HKCategorySample]
            let end: Date
            let asleepHours: Double
        }

        let candidates = clusters.compactMap { cluster -> Candidate? in
            guard let end = cluster.map(\.endDate).max() else { return nil }
            let totals = sleepTotals(from: cluster)
            guard totals.total > 0 else { return nil }
            return Candidate(samples: cluster, end: end, asleepHours: totals.total)
        }
        guard !candidates.isEmpty else { return [] }

        let wakeDayCandidates = candidates.filter { $0.end >= dayStart && $0.end <= dayEnd }
        let pool = wakeDayCandidates.isEmpty ? candidates : wakeDayCandidates
        return pool.max {
            if $0.asleepHours == $1.asleepHours {
                return $0.end < $1.end
            }
            return $0.asleepHours < $1.asleepHours
        }?.samples ?? []
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
        if stages.contains("Unstaged") { return "Unstaged" }
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

    nonisolated private static func isSleepAnalysisValue(_ value: Int) -> Bool {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue,
             HKCategoryValueSleepAnalysis.awake.rawValue,
             HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
             HKCategoryValueSleepAnalysis.asleepREM.rawValue,
             HKCategoryValueSleepAnalysis.asleepCore.rawValue,
             HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return true
        default:
            return false
        }
    }

    nonisolated private static func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs > rhs ? lhs : rhs
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
            case .authorizationDenied: return "Apple Health access was not granted"
            case .saveFailed: return "Apple Health did not save the exported fitness tracker data"
            case .deleteFailed: return "Apple Health did not replace the prior WarbFit sleep export"
            }
        }
    }
}

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .americanFootball: return "Football"
        case .archery: return "Archery"
        case .australianFootball: return "Australian Football"
        case .badminton: return "Badminton"
        case .barre: return "Barre"
        case .baseball: return "Baseball"
        case .basketball: return "Basketball"
        case .bowling: return "Bowling"
        case .boxing: return "Boxing"
        case .climbing: return "Climbing"
        case .cooldown: return "Cooldown"
        case .coreTraining: return "Core Training"
        case .cricket: return "Cricket"
        case .crossTraining: return "Cross Training"
        case .curling: return "Curling"
        case .cycling: return "Cycling"
        case .dance: return "Dance"
        case .discSports: return "Disc Sports"
        case .downhillSkiing: return "Downhill Skiing"
        case .elliptical: return "Elliptical"
        case .equestrianSports: return "Equestrian"
        case .fencing: return "Fencing"
        case .fishing: return "Fishing"
        case .fitnessGaming: return "Fitness Gaming"
        case .flexibility: return "Flexibility"
        case .functionalStrengthTraining: return "Strength Training"
        case .golf: return "Golf"
        case .gymnastics: return "Gymnastics"
        case .handball: return "Handball"
        case .highIntensityIntervalTraining: return "HIIT"
        case .hiking: return "Hiking"
        case .hockey: return "Hockey"
        case .hunting: return "Hunting"
        case .jumpRope: return "Jump Rope"
        case .kickboxing: return "Kickboxing"
        case .lacrosse: return "Lacrosse"
        case .martialArts: return "Martial Arts"
        case .mindAndBody: return "Mind and Body"
        case .mixedCardio: return "Mixed Cardio"
        case .other: return "Workout"
        case .pickleball: return "Pickleball"
        case .pilates: return "Pilates"
        case .play: return "Play"
        case .preparationAndRecovery: return "Recovery"
        case .racquetball: return "Racquetball"
        case .rowing: return "Rowing"
        case .rugby: return "Rugby"
        case .running: return "Run"
        case .sailing: return "Sailing"
        case .skatingSports: return "Skating"
        case .snowSports: return "Snow Sports"
        case .snowboarding: return "Snowboarding"
        case .soccer: return "Soccer"
        case .socialDance: return "Social Dance"
        case .softball: return "Softball"
        case .squash: return "Squash"
        case .stairClimbing, .stairs: return "Stairs"
        case .stepTraining: return "Step Training"
        case .surfingSports: return "Surfing"
        case .swimming: return "Swimming"
        case .tableTennis: return "Table Tennis"
        case .taiChi: return "Tai Chi"
        case .tennis: return "Tennis"
        case .traditionalStrengthTraining: return "Strength Training"
        case .volleyball: return "Volleyball"
        case .walking: return "Walk"
        case .waterFitness: return "Water Fitness"
        case .waterPolo: return "Water Polo"
        case .waterSports: return "Water Sports"
        case .wrestling: return "Wrestling"
        case .yoga: return "Yoga"
        default: return "Workout"
        }
    }
}
