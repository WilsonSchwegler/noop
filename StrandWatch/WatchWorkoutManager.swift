import Foundation
import HealthKit
import CoreLocation
import WatchConnectivity

struct WatchWorkoutOption: Identifiable, Equatable {
    let id: String
    let title: String
    let activityType: HKWorkoutActivityType
    let locationType: HKWorkoutSessionLocationType

    static let all: [WatchWorkoutOption] = [
        WatchWorkoutOption(id: "strength", title: "Strength", activityType: .traditionalStrengthTraining, locationType: .indoor),
        WatchWorkoutOption(id: "run", title: "Run", activityType: .running, locationType: .outdoor),
        WatchWorkoutOption(id: "hiking", title: "Hike", activityType: .hiking, locationType: .outdoor),
        WatchWorkoutOption(id: "treadmill", title: "Treadmill", activityType: .running, locationType: .indoor),
        WatchWorkoutOption(id: "swim", title: "Swim", activityType: .swimming, locationType: .indoor),
        WatchWorkoutOption(id: "stairmaster", title: "Stairs", activityType: .stairClimbing, locationType: .indoor),
    ]
}

struct WatchStrengthPlan: Identifiable, Equatable {
    let id: String
    let name: String
    let exercises: [WatchStrengthExercise]
}

struct WatchStrengthExercise: Identifiable, Equatable {
    let id: String
    let name: String
    let sets: Int
    let reps: Int
}

struct WatchStrengthSetLog: Identifiable, Equatable {
    let id: String
    let exerciseId: String
    let setIndex: Int
    var weight: String
}

struct WatchSwimPlan: Identifiable, Equatable {
    let id: String
    let name: String
    let items: [WatchSwimPlanItem]
}

struct WatchSwimPlanItem: Identifiable, Equatable {
    let id: String
    let stroke: String
    let sets: Int
    let distance: String
}

struct WatchRoutePoint: Identifiable, Equatable {
    let id = UUID()
    let ts: Int
    let latitude: Double
    let longitude: Double
    let altitude: Double?
}

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus = "Health access not requested"
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var selectedWorkout: WatchWorkoutOption = .all[0]
    @Published private(set) var startedAt: Date?
    @Published private(set) var heartRate: Double?
    @Published private(set) var activeEnergyKcal = 0.0
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var treadmillDistanceMiles = ""
    @Published private(set) var stairFlights = ""
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var strengthPlans: [WatchStrengthPlan] = []
    @Published private(set) var selectedStrengthPlan: WatchStrengthPlan?
    @Published private(set) var strengthSetLogs: [WatchStrengthSetLog] = []
    @Published private(set) var swimPlans: [WatchSwimPlan] = []
    @Published private(set) var selectedSwimPlan: WatchSwimPlan?
    @Published private(set) var status = "Ready"

    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var connectivity: WCSession?
    private var elapsedTimer: Timer?
    private var workoutSessionId = UUID().uuidString
    private var healthDistanceMeters = 0.0
    private var treadmillDistanceMetersOverride: Double?
    private var routePoints: [WatchRoutePoint] = []
    private var pendingRoutePoints: [WatchRoutePoint] = []

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.activityType = .fitness
        configureConnectivity()
    }

    func select(_ option: WatchWorkoutOption) {
        guard !isRunning else { return }
        selectedWorkout = option
        if option.id != "strength" {
            selectedStrengthPlan = nil
            strengthSetLogs = []
        }
        if option.id != "swim" {
            selectedSwimPlan = nil
        }
        treadmillDistanceMiles = ""
        stairFlights = ""
    }

    func startStrength(plan: WatchStrengthPlan?) {
        guard let strength = Self.allOption(id: "strength") else { return }
        selectedWorkout = strength
        selectedStrengthPlan = plan
        strengthSetLogs = Self.initialSetLogs(for: plan)
        start()
    }

    func startSwim(plan: WatchSwimPlan?) {
        guard let swim = Self.allOption(id: "swim") else { return }
        selectedWorkout = swim
        selectedSwimPlan = plan
        start()
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = "HealthKit is not available"
            return
        }
        healthStore.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.authorizationStatus = error.localizedDescription
                } else {
                    self.authorizationStatus = success ? "Health access enabled" : "Health access denied"
                }
            }
        }
    }

    func start(sessionId: String? = nil) {
        guard !isRunning else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = "HealthKit is not available"
            return
        }
        healthStore.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.authorizationStatus = error.localizedDescription
                } else if success {
                    self.authorizationStatus = "Health access enabled"
                    self.beginWorkout(sessionId: sessionId ?? UUID().uuidString)
                } else {
                    self.authorizationStatus = "Health access denied"
                    self.status = "Health access is required to start workouts"
                }
            }
        }
    }

    private func beginWorkout(sessionId: String) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = selectedWorkout.activityType
        configuration.locationType = selectedWorkout.locationType
        if selectedWorkout.id == "swim" {
            configuration.swimmingLocationType = .pool
            configuration.lapLength = HKQuantity(unit: .yard(), doubleValue: 25)
        }

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            workoutSessionId = sessionId

            let startDate = Date()
            startedAt = startDate
            isRunning = true
            isPaused = false
            heartRate = nil
            activeEnergyKcal = 0
            healthDistanceMeters = 0
            distanceMeters = 0
            treadmillDistanceMetersOverride = nil
            routePoints = []
            pendingRoutePoints = []
            treadmillDistanceMiles = ""
            stairFlights = ""
            elapsedSeconds = 0
            status = "Workout running"
            startElapsedTimer()

            session.startActivity(with: startDate)
            startLocationUpdatesIfNeeded()
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.status = "Collection failed: \(error.localizedDescription)"
                    } else if success {
                        self.sendSnapshot(event: "started")
                    }
                }
            }
        } catch {
            status = "Workout failed: \(error.localizedDescription)"
        }
    }

    func togglePause() {
        guard isRunning, let session else { return }
        if isPaused {
            session.resume()
        } else {
            session.pause()
        }
    }

    func end() {
        guard isRunning else { return }
        status = "Saving workout"
        session?.end()
    }

    func updateWeight(exerciseId: String, setIndex: Int, weight: String) {
        guard let index = strengthSetLogs.firstIndex(where: { $0.exerciseId == exerciseId && $0.setIndex == setIndex }) else { return }
        strengthSetLogs[index].weight = weight
        sendSnapshot(event: "strengthLog")
    }

    func updateTreadmillDistanceMiles(_ distance: String) {
        treadmillDistanceMiles = Self.cleanedDecimalInput(distance)
        if let miles = Double(treadmillDistanceMiles), miles > 0 {
            treadmillDistanceMetersOverride = miles * 1609.344
        } else {
            treadmillDistanceMetersOverride = nil
        }
        refreshDisplayedDistance()
        sendSnapshot(event: "treadmillDistance")
    }

    func updateStairFlights(_ flights: String) {
        stairFlights = Self.cleanedIntegerInput(flights)
        sendSnapshot(event: "stairFlights")
    }

    private func finishWorkout() {
        guard let builder else { return }
        let endDate = Date()
        builder.endCollection(withEnd: endDate) { [weak self] _, error in
            guard let self else { return }
            builder.finishWorkout { _, finishError in
                Task { @MainActor in
                    self.status = (error ?? finishError).map { "Save failed: \($0.localizedDescription)" } ?? "Workout saved to Health"
                    let finalRoutePoints = self.pendingRoutePoints
                    self.sendRoutePoints(force: true)
                    self.sendSnapshot(event: "ended", routePoints: finalRoutePoints)
                    self.resetWorkoutState()
                }
            }
        }
    }

    private func resetWorkoutState() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        session = nil
        builder = nil
        isRunning = false
        isPaused = false
        startedAt = nil
        selectedStrengthPlan = nil
        selectedSwimPlan = nil
        strengthSetLogs = []
        routePoints = []
        pendingRoutePoints = []
        healthDistanceMeters = 0
        distanceMeters = 0
        treadmillDistanceMetersOverride = nil
        treadmillDistanceMiles = ""
        stairFlights = ""
        stopLocationUpdates()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
                self.sendSnapshot(event: "tick")
            }
        }
    }

    private func configureConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        connectivity = session
    }

    private func updateStatistics(for statistics: HKStatistics?) {
        guard let statistics else { return }
        switch statistics.quantityType {
        case HKQuantityType.quantityType(forIdentifier: .heartRate):
            heartRate = statistics.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
            activeEnergyKcal = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? activeEnergyKcal
        case HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
             HKQuantityType.quantityType(forIdentifier: .distanceCycling),
             HKQuantityType.quantityType(forIdentifier: .distanceSwimming):
            healthDistanceMeters = statistics.sumQuantity()?.doubleValue(for: .meter()) ?? healthDistanceMeters
            refreshDisplayedDistance()
        default:
            break
        }
    }

    private func refreshDisplayedDistance() {
        if selectedWorkout.id == "treadmill", let treadmillDistanceMetersOverride {
            distanceMeters = treadmillDistanceMetersOverride
        } else {
            distanceMeters = healthDistanceMeters
        }
    }

    private func sendSnapshot(event: String, routePoints routePointBatch: [WatchRoutePoint] = []) {
        guard WCSession.isSupported() else { return }
        let running = event == "ended" || event == "failed" ? false : isRunning
        var payload: [String: Any] = [
            "kind": "warbfit.watch.workout",
            "event": event,
            "workoutSessionId": workoutSessionId,
            "workoutTypeId": selectedWorkout.id,
            "workoutId": workoutSessionId.isEmpty ? selectedWorkout.id : workoutSessionId,
            "workoutName": selectedWorkout.title,
            "planId": selectedStrengthPlan?.id ?? selectedSwimPlan?.id ?? "",
            "planName": selectedStrengthPlan?.name ?? selectedSwimPlan?.name ?? "",
            "strengthSetLogs": strengthSetLogs.map(Self.encodeStrengthSetLog),
            "startedAt": startedAt?.timeIntervalSince1970 ?? 0,
            "elapsedSeconds": elapsedSeconds,
            "heartRate": heartRate ?? 0,
            "activeEnergyKcal": activeEnergyKcal,
            "distanceMeters": distanceMeters,
            "treadmillDistance": treadmillDistanceMiles,
            "stairFlights": stairFlights,
            "isRunning": running,
            "isPaused": isPaused,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if !routePointBatch.isEmpty {
            payload["routePoints"] = Self.encodeRoutePoints(Self.simplifiedRoute(routePointBatch, maxPoints: 50))
        }
        try? connectivity?.updateApplicationContext(payload)
        if connectivity?.isReachable == true {
            connectivity?.sendMessage(payload, replyHandler: nil)
        }
    }

    private func sendRoutePoints(force: Bool = false) {
        guard WCSession.isSupported(), let connectivity, !pendingRoutePoints.isEmpty else { return }
        guard force || pendingRoutePoints.count >= 5 else { return }

        let pointsToSend = pendingRoutePoints
        pendingRoutePoints = []

        var startIndex = 0
        while startIndex < pointsToSend.count {
            let endIndex = min(pointsToSend.count, startIndex + 25)
            let batch = Array(pointsToSend[startIndex..<endIndex])
            let payload: [String: Any] = [
                "kind": "warbfit.watch.workout.route",
                "workoutSessionId": workoutSessionId,
                "startedAt": startedAt?.timeIntervalSince1970 ?? 0,
                "routePoints": Self.encodeRoutePoints(batch),
                "updatedAt": Date().timeIntervalSince1970,
            ]
            connectivity.transferUserInfo(payload)
            if connectivity.isReachable {
                connectivity.sendMessage(payload, replyHandler: nil)
            }
            startIndex = endIndex
        }
    }

    private static var readTypes: Set<HKObjectType> {
        Set([
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKQuantityType.quantityType(forIdentifier: .distanceCycling),
            HKQuantityType.quantityType(forIdentifier: .distanceSwimming),
            HKObjectType.workoutType(),
        ].compactMap { $0 })
    }

    private static var shareTypes: Set<HKSampleType> {
        Set([
            HKObjectType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKQuantityType.quantityType(forIdentifier: .distanceCycling),
            HKQuantityType.quantityType(forIdentifier: .distanceSwimming),
        ].compactMap { $0 })
    }

    private func applyPhonePlans(_ payload: [String: Any]) {
        strengthPlans = Self.decodeStrengthPlans(payload["strengthPlans"] as? [[String: Any]])
        swimPlans = Self.decodeSwimPlans(payload["swimPlans"] as? [[String: Any]])
    }

    private func applyPhoneWorkout(_ payload: [String: Any]) {
        let event = payload["event"] as? String ?? "running"
        let incomingSessionId = payload["workoutSessionId"] as? String ?? ""
        if event == "ended" || event == "discarded" {
            if isRunning, incomingSessionId == workoutSessionId {
                end()
            }
            return
        }

        let typeId = payload["workoutTypeId"] as? String ?? "workout"
        if let option = Self.allOption(id: typeId) {
            selectedWorkout = option
        }
        if selectedWorkout.id == "strength" {
            let planId = payload["planId"] as? String ?? ""
            selectedStrengthPlan = strengthPlans.first { $0.id == planId }
            let incomingLogs = Self.decodeStrengthSetLogs(payload["strengthSetLogs"] as? [[String: Any]])
            let currentLogs = strengthSetLogs.isEmpty ? Self.initialSetLogs(for: selectedStrengthPlan) : strengthSetLogs
            strengthSetLogs = incomingLogs.isEmpty
                ? currentLogs
                : Self.mergedStrengthSetLogs(current: currentLogs, incoming: incomingLogs)
        }
        if selectedWorkout.id == "swim" {
            let planId = payload["planId"] as? String ?? ""
            selectedSwimPlan = swimPlans.first { $0.id == planId }
        }
        treadmillDistanceMiles = payload["treadmillDistance"] as? String ?? treadmillDistanceMiles
        stairFlights = payload["stairFlights"] as? String ?? stairFlights

        if isRunning {
            return
        }
        start(sessionId: incomingSessionId.isEmpty ? UUID().uuidString : incomingSessionId)
    }

    private static func allOption(id: String) -> WatchWorkoutOption? {
        WatchWorkoutOption.all.first { $0.id == id }
    }

    private static func initialSetLogs(for plan: WatchStrengthPlan?) -> [WatchStrengthSetLog] {
        plan?.exercises.flatMap { exercise in
            (1...max(1, exercise.sets)).map {
                WatchStrengthSetLog(id: UUID().uuidString, exerciseId: exercise.id, setIndex: $0, weight: "")
            }
        } ?? []
    }

    private static func encodeStrengthSetLog(_ log: WatchStrengthSetLog) -> [String: Any] {
        [
            "id": log.id,
            "exerciseId": log.exerciseId,
            "setIndex": log.setIndex,
            "weight": log.weight,
        ]
    }

    private static func encodeRoutePoints(_ points: [WatchRoutePoint]) -> [[String: Any]] {
        points.map { point in
            var row: [String: Any] = [
                "ts": point.ts,
                "latitude": point.latitude,
                "longitude": point.longitude,
            ]
            if let altitude = point.altitude {
                row["altitude"] = altitude
            }
            return row
        }
    }

    private static func decodeStrengthPlans(_ rows: [[String: Any]]?) -> [WatchStrengthPlan] {
        rows?.compactMap { row in
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String else { return nil }
            let exercises = (row["exercises"] as? [[String: Any]])?.compactMap { exercise -> WatchStrengthExercise? in
                guard let exerciseId = exercise["id"] as? String,
                      let exerciseName = exercise["name"] as? String else { return nil }
                return WatchStrengthExercise(
                    id: exerciseId,
                    name: exerciseName,
                    sets: exercise["sets"] as? Int ?? 1,
                    reps: exercise["reps"] as? Int ?? 1
                )
            } ?? []
            return WatchStrengthPlan(id: id, name: name, exercises: exercises)
        } ?? []
    }

    private static func decodeSwimPlans(_ rows: [[String: Any]]?) -> [WatchSwimPlan] {
        rows?.compactMap { row in
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String else { return nil }
            let items = (row["items"] as? [[String: Any]])?.compactMap { item -> WatchSwimPlanItem? in
                guard let itemId = item["id"] as? String else { return nil }
                return WatchSwimPlanItem(
                    id: itemId,
                    stroke: item["stroke"] as? String ?? "Swim",
                    sets: item["sets"] as? Int ?? 1,
                    distance: item["distance"] as? String ?? ""
                )
            } ?? []
            return WatchSwimPlan(id: id, name: name, items: items)
        } ?? []
    }

    private static func decodeStrengthSetLogs(_ rows: [[String: Any]]?) -> [WatchStrengthSetLog] {
        rows?.compactMap { row in
            guard let exerciseId = row["exerciseId"] as? String,
                  let setIndex = row["setIndex"] as? Int else { return nil }
            return WatchStrengthSetLog(
                id: row["id"] as? String ?? UUID().uuidString,
                exerciseId: exerciseId,
                setIndex: setIndex,
                weight: row["weight"] as? String ?? ""
            )
        } ?? []
    }

    private static func cleanedDecimalInput(_ value: String) -> String {
        let allowed = Set("0123456789.")
        var output = ""
        var hasDecimal = false
        for character in value where allowed.contains(character) {
            if character == "." {
                guard !hasDecimal else { continue }
                hasDecimal = true
            }
            output.append(character)
        }
        return output
    }

    private static func cleanedIntegerInput(_ value: String) -> String {
        value.filter { $0.isNumber }
    }

    private static func mergedStrengthSetLogs(current: [WatchStrengthSetLog],
                                              incoming: [WatchStrengthSetLog]) -> [WatchStrengthSetLog] {
        guard !current.isEmpty else { return incoming }
        var logs = current
        for incomingLog in incoming {
            guard let index = logs.firstIndex(where: {
                $0.exerciseId == incomingLog.exerciseId && $0.setIndex == incomingLog.setIndex
            }) else {
                logs.append(incomingLog)
                continue
            }
            let incomingWeight = incomingLog.weight.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentWeight = logs[index].weight.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingWeight.isEmpty || currentWeight.isEmpty {
                logs[index].weight = incomingLog.weight
            }
        }
        return logs.sorted {
            if $0.exerciseId == $1.exerciseId { return $0.setIndex < $1.setIndex }
            return $0.exerciseId < $1.exerciseId
        }
    }

    private func startLocationUpdatesIfNeeded() {
        guard selectedWorkout.locationType == .outdoor else {
            stopLocationUpdates()
            return
        }
        guard CLLocationManager.locationServicesEnabled() else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
    }

    private func appendRouteLocation(_ location: CLLocation) {
        guard selectedWorkout.locationType == .outdoor else { return }
        guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 else { return }
        let point = WatchRoutePoint(
            ts: Int(location.timestamp.timeIntervalSince1970),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
        if let last = routePoints.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            guard previous.distance(from: location) >= 8 else { return }
        }
        routePoints.append(point)
        pendingRoutePoints.append(point)
        if routePoints.count > 650 {
            routePoints = Self.simplifiedRoute(routePoints, maxPoints: 500)
        }
        sendRoutePoints()
    }

    private static func simplifiedRoute(_ points: [WatchRoutePoint], maxPoints: Int) -> [WatchRoutePoint] {
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
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            switch toState {
            case .running:
                isPaused = false
                isRunning = true
                status = "Workout running"
                startLocationUpdatesIfNeeded()
                sendSnapshot(event: "running")
            case .paused:
                isPaused = true
                status = "Workout paused"
                stopLocationUpdates()
                sendSnapshot(event: "paused")
            case .ended:
                finishWorkout()
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            status = "Workout failed: \(error.localizedDescription)"
            sendSnapshot(event: "failed")
            resetWorkoutState()
        }
    }
}

extension WatchWorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isRunning, !self.isPaused {
                self.startLocationUpdatesIfNeeded()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            locations.forEach { self.appendRouteLocation($0) }
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            for type in collectedTypes {
                guard let quantityType = type as? HKQuantityType else { continue }
                updateStatistics(for: workoutBuilder.statistics(for: quantityType))
            }
            sendSnapshot(event: "metrics")
        }
    }
}

extension WatchWorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            applyConnectivityPayload(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            applyConnectivityPayload(applicationContext)
        }
    }

    private func applyConnectivityPayload(_ payload: [String: Any]) {
        switch payload["kind"] as? String {
        case "warbfit.phone.plans":
            applyPhonePlans(payload)
        case "warbfit.phone.workout":
            applyPhoneWorkout(payload)
        default:
            break
        }
    }
}
