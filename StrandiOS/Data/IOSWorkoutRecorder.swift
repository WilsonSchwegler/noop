import CoreLocation
import Foundation
import StrandAnalytics
import WhoopProtocol

struct IOSWorkoutType: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String

    static let all: [IOSWorkoutType] = [
        IOSWorkoutType(id: "strength", name: "Strength Training", icon: "dumbbell.fill"),
        IOSWorkoutType(id: "swim", name: "Swimming", icon: "figure.pool.swim"),
        IOSWorkoutType(id: "treadmill", name: "Treadmill", icon: "figure.run"),
        IOSWorkoutType(id: "run", name: "Run", icon: "figure.run"),
        IOSWorkoutType(id: "hiking", name: "Hiking", icon: "figure.hiking"),
        IOSWorkoutType(id: "stairmaster", name: "Stair Master", icon: "figure.stairs"),
    ]
}

struct IOSWorkoutHRSample: Identifiable, Codable, Equatable {
    let id: UUID
    let ts: Int
    let bpm: Int

    init(id: UUID = UUID(), ts: Int, bpm: Int) {
        self.id = id
        self.ts = ts
        self.bpm = bpm
    }
}

enum IOSWorkoutPlanKind: String, Codable, CaseIterable, Equatable {
    case strength
    case swim

    var title: String {
        switch self {
        case .strength: return "Strength Training"
        case .swim: return "Swimming"
        }
    }
}

struct IOSStrengthPlanExercise: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sets: Int
    var reps: Int

    init(id: UUID = UUID(), name: String, sets: Int, reps: Int) {
        self.id = id
        self.name = name
        self.sets = sets
        self.reps = reps
    }
}

struct IOSSwimPlanItem: Identifiable, Codable, Equatable {
    let id: UUID
    var stroke: String
    var sets: Int
    var distance: String

    init(id: UUID = UUID(), stroke: String, sets: Int, distance: String) {
        self.id = id
        self.stroke = stroke
        self.sets = sets
        self.distance = distance
    }
}

struct IOSWorkoutPlan: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: IOSWorkoutPlanKind
    var name: String
    var strengthExercises: [IOSStrengthPlanExercise]
    var swimItems: [IOSSwimPlanItem]
    var createdAt: Date

    init(id: UUID = UUID(),
         kind: IOSWorkoutPlanKind,
         name: String,
         strengthExercises: [IOSStrengthPlanExercise] = [],
         swimItems: [IOSSwimPlanItem] = [],
         createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.strengthExercises = strengthExercises
        self.swimItems = swimItems
        self.createdAt = createdAt
    }
}

struct IOSStrengthSetLog: Identifiable, Codable, Equatable {
    let id: UUID
    let exerciseId: UUID
    let setIndex: Int
    var weight: String

    init(id: UUID = UUID(), exerciseId: UUID, setIndex: Int, weight: String = "") {
        self.id = id
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.weight = weight
    }
}

struct IOSRoutePoint: Identifiable, Codable, Equatable {
    let id: UUID
    let ts: Int
    let latitude: Double
    let longitude: Double
    let altitude: Double?

    init(id: UUID = UUID(), ts: Int, latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.id = id
        self.ts = ts
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

struct IOSLoggedWorkout: Identifiable, Codable, Equatable {
    let id: UUID
    let typeId: String
    let typeName: String
    let startedAt: Date
    let endedAt: Date
    let notes: String
    let hrSamples: [IOSWorkoutHRSample]
    let strain: Double?
    let planId: UUID?
    let planName: String?
    let planSnapshot: IOSWorkoutPlan?
    let strengthSetLogs: [IOSStrengthSetLog]
    let routePoints: [IOSRoutePoint]
    let distanceMeters: Double?
    let treadmillDistance: String?
    let stairFlights: String?

    init(id: UUID,
         typeId: String,
         typeName: String,
         startedAt: Date,
         endedAt: Date,
         notes: String,
         hrSamples: [IOSWorkoutHRSample],
         strain: Double?,
         planId: UUID? = nil,
         planName: String? = nil,
         planSnapshot: IOSWorkoutPlan? = nil,
         strengthSetLogs: [IOSStrengthSetLog] = [],
         routePoints: [IOSRoutePoint] = [],
         distanceMeters: Double? = nil,
         treadmillDistance: String? = nil,
         stairFlights: String? = nil) {
        self.id = id
        self.typeId = typeId
        self.typeName = typeName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.hrSamples = hrSamples
        self.strain = strain
        self.planId = planId
        self.planName = planName
        self.planSnapshot = planSnapshot
        self.strengthSetLogs = strengthSetLogs
        self.routePoints = routePoints
        self.distanceMeters = distanceMeters
        self.treadmillDistance = treadmillDistance
        self.stairFlights = stairFlights
    }

    private enum CodingKeys: String, CodingKey {
        case id, typeId, typeName, startedAt, endedAt, notes, hrSamples, strain
        case planId, planName, planSnapshot, strengthSetLogs
        case routePoints, distanceMeters, treadmillDistance, stairFlights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        typeId = try c.decode(String.self, forKey: .typeId)
        typeName = try c.decode(String.self, forKey: .typeName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        notes = try c.decode(String.self, forKey: .notes)
        hrSamples = try c.decode([IOSWorkoutHRSample].self, forKey: .hrSamples)
        strain = try c.decodeIfPresent(Double.self, forKey: .strain)
        planId = try c.decodeIfPresent(UUID.self, forKey: .planId)
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
        planSnapshot = try c.decodeIfPresent(IOSWorkoutPlan.self, forKey: .planSnapshot)
        strengthSetLogs = try c.decodeIfPresent([IOSStrengthSetLog].self, forKey: .strengthSetLogs) ?? []
        routePoints = try c.decodeIfPresent([IOSRoutePoint].self, forKey: .routePoints) ?? []
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        treadmillDistance = try c.decodeIfPresent(String.self, forKey: .treadmillDistance)
        stairFlights = try c.decodeIfPresent(String.self, forKey: .stairFlights)
    }

    var durationSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var avgHR: Int? {
        guard !hrSamples.isEmpty else { return nil }
        return Int((Double(hrSamples.reduce(0) { $0 + $1.bpm }) / Double(hrSamples.count)).rounded())
    }
    var maxHR: Int? { hrSamples.map(\.bpm).max() }
    var paceSecondsPerMile: Double? {
        guard let distanceMeters, distanceMeters > 0 else { return nil }
        let miles = distanceMeters / 1609.344
        guard miles > 0 else { return nil }
        return durationSeconds / miles
    }
    var effectiveStrain: Double? {
        strain ?? IOSStrainEstimator.strain(
            hr: hrSamples.map { HRSample(ts: $0.ts, bpm: $0.bpm) },
            workoutTypeId: typeId
        )
    }
}

struct IOSActiveWorkout: Equatable {
    let id: UUID
    let type: IOSWorkoutType
    let startedAt: Date
    var notes: String
    var hrSamples: [IOSWorkoutHRSample]
    var plan: IOSWorkoutPlan?
    var strengthSetLogs: [IOSStrengthSetLog]
    var routePoints: [IOSRoutePoint]
    var distanceMeters: Double
    var treadmillDistance: String
    var stairFlights: String

    var durationSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }
    var avgHR: Int? {
        guard !hrSamples.isEmpty else { return nil }
        return Int((Double(hrSamples.reduce(0) { $0 + $1.bpm }) / Double(hrSamples.count)).rounded())
    }
    var maxHR: Int? { hrSamples.map(\.bpm).max() }
    var paceSecondsPerMile: Double? {
        guard distanceMeters > 0 else { return nil }
        return durationSeconds / (distanceMeters / 1609.344)
    }
}

@MainActor
final class IOSWorkoutRecorder: NSObject, ObservableObject {
    @Published private(set) var active: IOSActiveWorkout?
    @Published private(set) var workouts: [IOSLoggedWorkout] = []
    @Published private(set) var plans: [IOSWorkoutPlan] = []

    private let storageKey = "warbfit.ios.workoutLog.v1"
    private let plansStorageKey = "warbfit.ios.workoutPlans.v1"
    private let locationManager = CLLocationManager()
    @Published private(set) var locationStatus = "Location not requested"

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5
        locationManager.pausesLocationUpdatesAutomatically = false
        if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [] ~= "location" {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        load()
        loadPlans()
    }

    func start(_ type: IOSWorkoutType, plan: IOSWorkoutPlan? = nil) {
        active = IOSActiveWorkout(
            id: UUID(),
            type: type,
            startedAt: Date(),
            notes: "",
            hrSamples: [],
            plan: plan,
            strengthSetLogs: Self.initialSetLogs(for: plan),
            routePoints: [],
            distanceMeters: 0,
            treadmillDistance: "",
            stairFlights: ""
        )
        if type.id == "run" || type.id == "hiking" {
            startLocationUpdates()
        }
    }

    func record(heartRate: Int?) {
        guard var active, let heartRate, heartRate >= 30, heartRate <= 220 else { return }
        let ts = Int(Date().timeIntervalSince1970)
        if active.hrSamples.last?.ts == ts { return }
        active.hrSamples.append(IOSWorkoutHRSample(ts: ts, bpm: heartRate))
        self.active = active
    }

    func updateTreadmillDistance(_ distance: String) {
        guard var active else { return }
        active.treadmillDistance = distance
        self.active = active
    }

    func updateStairFlights(_ flights: String) {
        guard var active else { return }
        active.stairFlights = flights
        self.active = active
    }

    func updateNotes(_ notes: String) {
        guard var active else { return }
        active.notes = notes
        self.active = active
    }

    func updateSetWeight(exerciseId: UUID, setIndex: Int, weight: String) {
        guard var active else { return }
        guard let index = active.strengthSetLogs.firstIndex(where: { $0.exerciseId == exerciseId && $0.setIndex == setIndex }) else { return }
        active.strengthSetLogs[index].weight = weight
        self.active = active
    }

    func finish() {
        guard let active else { return }
        let logged = IOSLoggedWorkout(
            id: active.id,
            typeId: active.type.id,
            typeName: active.type.name,
            startedAt: active.startedAt,
            endedAt: Date(),
            notes: active.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            hrSamples: active.hrSamples,
            strain: strain(for: active.hrSamples, workoutTypeId: active.type.id),
            planId: active.plan?.id,
            planName: active.plan?.name,
            planSnapshot: active.plan,
            strengthSetLogs: active.strengthSetLogs,
            routePoints: active.routePoints,
            distanceMeters: active.distanceMeters > 0 ? active.distanceMeters : nil,
            treadmillDistance: active.treadmillDistance.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            stairFlights: active.stairFlights.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        workouts.insert(logged, at: 0)
        workouts = Array(workouts.prefix(50))
        self.active = nil
        stopLocationUpdates()
        save()
    }

    func discard() {
        active = nil
        stopLocationUpdates()
    }

    func delete(_ workout: IOSLoggedWorkout) {
        workouts.removeAll { $0.id == workout.id }
        save()
    }

    func addPlan(_ plan: IOSWorkoutPlan) {
        plans.insert(plan, at: 0)
        savePlans()
    }

    func updatePlan(_ plan: IOSWorkoutPlan) {
        guard let index = plans.firstIndex(where: { $0.id == plan.id }) else {
            addPlan(plan)
            return
        }
        plans[index] = plan
        savePlans()
    }

    func deletePlan(_ plan: IOSWorkoutPlan) {
        plans.removeAll { $0.id == plan.id }
        savePlans()
    }

    func restoreBackup(workouts importedWorkouts: [IOSLoggedWorkout]?,
                       plans importedPlans: [IOSWorkoutPlan]?) -> (workouts: Int, plans: Int) {
        active = nil
        stopLocationUpdates()

        if let importedWorkouts {
            workouts = importedWorkouts.sorted { $0.startedAt > $1.startedAt }
            save()
        }
        if let importedPlans {
            plans = importedPlans.sorted { $0.createdAt > $1.createdAt }
            savePlans()
        }
        return (workouts.count, plans.count)
    }

    func plans(for type: IOSWorkoutType) -> [IOSWorkoutPlan] {
        let kind: IOSWorkoutPlanKind?
        switch type.id {
        case "strength": kind = .strength
        case "swim": kind = .swim
        default: kind = nil
        }
        guard let kind else { return [] }
        return plans.filter { $0.kind == kind }
    }

    func previousWeight(planId: UUID, exerciseId: UUID, setIndex: Int, before date: Date = Date()) -> String? {
        workouts
            .filter { $0.planId == planId && $0.startedAt < date }
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { workout in
                workout.strengthSetLogs.first { $0.exerciseId == exerciseId && $0.setIndex == setIndex }?.weight
            }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func strain(for samples: [IOSWorkoutHRSample], workoutTypeId: String? = nil) -> Double? {
        let hr = samples.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        return IOSStrainEstimator.strain(hr: hr, workoutTypeId: workoutTypeId)
    }

    func elapsedString(for seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([IOSLoggedWorkout].self, from: data) else { return }
        workouts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workouts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadPlans() {
        guard let data = UserDefaults.standard.data(forKey: plansStorageKey),
              let decoded = try? JSONDecoder().decode([IOSWorkoutPlan].self, from: data) else { return }
        plans = decoded
    }

    private func savePlans() {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        UserDefaults.standard.set(data, forKey: plansStorageKey)
    }

    private static func initialSetLogs(for plan: IOSWorkoutPlan?) -> [IOSStrengthSetLog] {
        guard plan?.kind == .strength else { return [] }
        return plan?.strengthExercises.flatMap { exercise in
            (1...max(1, exercise.sets)).map { IOSStrengthSetLog(exerciseId: exercise.id, setIndex: $0) }
        } ?? []
    }

    private func startLocationUpdates() {
        guard active?.type.id == "run" || active?.type.id == "hiking" else {
            stopLocationUpdates()
            locationStatus = "Location idle"
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            locationStatus = "Location services are off"
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationStatus = "Requesting location access"
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationStatus = "Recording route"
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            locationStatus = "Location access denied"
        @unknown default:
            locationStatus = "Location unavailable"
        }
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationStatus = "Location idle"
    }

    private func appendRouteLocation(_ location: CLLocation) {
        guard var active, active.type.id == "run" || active.type.id == "hiking" else { return }
        guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 else { return }
        let point = IOSRoutePoint(
            ts: Int(location.timestamp.timeIntervalSince1970),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
        if let last = active.routePoints.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let delta = previous.distance(from: location)
            guard delta >= 2 else { return }
            active.distanceMeters += delta
        }
        active.routePoints.append(point)
        self.active = active
    }
}

extension IOSWorkoutRecorder: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.active?.type.id == "run" || self.active?.type.id == "hiking" {
                self.startLocationUpdates()
            } else {
                self.stopLocationUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            locations.forEach { self.appendRouteLocation($0) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationStatus = "Location failed: \(error.localizedDescription)"
        }
    }
}

private func ~= (modes: [String], value: String) -> Bool {
    modes.contains(value)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
