import Foundation
import WatchConnectivity

struct IOSWatchWorkoutSnapshot: Equatable {
    var workoutId: String
    var workoutTypeId: String
    var workoutName: String
    var event: String
    var planId: UUID?
    var planName: String?
    var strengthSetLogs: [IOSStrengthSetLog]
    var routePoints: [IOSRoutePoint]
    var startedAt: Date?
    var elapsedSeconds: TimeInterval
    var heartRate: Int?
    var activeEnergyKcal: Double
    var distanceMeters: Double
    var treadmillDistance: String
    var stairFlights: String
    var isRunning: Bool
    var isPaused: Bool
    var updatedAt: Date
}

@MainActor
final class IOSWatchWorkoutBridge: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var isReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var activationStatus = "Companion not connected"
    @Published private(set) var liveWorkout: IOSWatchWorkoutSnapshot?
    @Published private(set) var completedWorkout: IOSWatchWorkoutSnapshot?
    @Published private(set) var completedWorkoutToken = ""

    private var session: WCSession?
    private var heartRateSamplesByWorkout: [String: [IOSWorkoutHRSample]] = [:]
    private var routePointsByWorkout: [String: [IOSRoutePoint]] = [:]
    private var lastSentActiveContextAt: Date?

    override init() {
        super.init()
        configure()
    }

    func configure() {
        guard WCSession.isSupported() else {
            activationStatus = "Companion connection is not supported"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        updateAvailability(from: session)
    }

    var isCompanionAvailable: Bool {
        isSupported && isPaired
    }

    private func updateAvailability(from session: WCSession) {
        isReachable = session.isReachable
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled

        if session.isReachable {
            activationStatus = "Companion ready"
        } else if !session.isPaired {
            activationStatus = "No paired watch"
        } else if !session.isWatchAppInstalled {
            activationStatus = "Watch paired, install companion app"
        } else if session.activationState == .activated {
            activationStatus = "Watch paired"
        } else {
            activationStatus = "Companion activating"
        }
    }

    private func apply(_ payload: [String: Any]) {
        switch payload["kind"] as? String {
        case "warbfit.watch.workout":
            applyWorkoutSnapshot(payload)
        case "warbfit.watch.workout.route":
            applyRoutePayload(payload)
        default:
            return
        }
    }

    private func applyWorkoutSnapshot(_ payload: [String: Any]) {
        let startedAtSeconds = payload["startedAt"] as? Double ?? 0
        let updatedAtSeconds = payload["updatedAt"] as? Double ?? Date().timeIntervalSince1970
        let updatedAt = Date(timeIntervalSince1970: updatedAtSeconds)
        let heartRateValue = payload["heartRate"] as? Double ?? 0
        let workoutTypeId = payload["workoutTypeId"] as? String
            ?? payload["workoutId"] as? String
            ?? "workout"
        let workoutId = payload["workoutSessionId"] as? String
            ?? "legacy-\(workoutTypeId)-\(Int(startedAtSeconds))"
        let event = payload["event"] as? String ?? "metrics"
        if heartRateValue > 0 {
            appendHeartRateSample(workoutId: workoutId, bpm: Int(heartRateValue.rounded()), at: updatedAt)
        }
        let routePoints = mergeRoutePoints(
            workoutId: workoutId,
            incoming: Self.decodeRoutePoints(payload["routePoints"] as? [[String: Any]])
        )
        let snapshot = IOSWatchWorkoutSnapshot(
            workoutId: workoutId,
            workoutTypeId: workoutTypeId,
            workoutName: payload["workoutName"] as? String ?? "Companion Workout",
            event: event,
            planId: (payload["planId"] as? String).flatMap(UUID.init(uuidString:)),
            planName: payload["planName"] as? String,
            strengthSetLogs: Self.decodeStrengthSetLogs(payload["strengthSetLogs"] as? [[String: Any]]),
            routePoints: routePoints,
            startedAt: startedAtSeconds > 0 ? Date(timeIntervalSince1970: startedAtSeconds) : nil,
            elapsedSeconds: payload["elapsedSeconds"] as? Double ?? 0,
            heartRate: heartRateValue > 0 ? Int(heartRateValue.rounded()) : nil,
            activeEnergyKcal: payload["activeEnergyKcal"] as? Double ?? 0,
            distanceMeters: payload["distanceMeters"] as? Double ?? 0,
            treadmillDistance: payload["treadmillDistance"] as? String ?? "",
            stairFlights: payload["stairFlights"] as? String ?? "",
            isRunning: payload["isRunning"] as? Bool ?? false,
            isPaused: payload["isPaused"] as? Bool ?? false,
            updatedAt: updatedAt
        )
        if snapshot.isRunning {
            liveWorkout = snapshot
        } else {
            liveWorkout = nil
            completedWorkout = snapshot
            completedWorkoutToken = "\(snapshot.workoutId)-\(Int(snapshot.updatedAt.timeIntervalSince1970))"
        }
    }

    private func applyRoutePayload(_ payload: [String: Any]) {
        guard let workoutId = payload["workoutSessionId"] as? String else { return }
        let updatedAtSeconds = payload["updatedAt"] as? Double ?? Date().timeIntervalSince1970
        let routePoints = mergeRoutePoints(
            workoutId: workoutId,
            incoming: Self.decodeRoutePoints(payload["routePoints"] as? [[String: Any]])
        )
        guard !routePoints.isEmpty else { return }
        let updatedAt = Date(timeIntervalSince1970: updatedAtSeconds)
        if var liveWorkout, liveWorkout.workoutId == workoutId {
            liveWorkout.routePoints = routePoints
            liveWorkout.updatedAt = updatedAt
            self.liveWorkout = liveWorkout
        }
        if var completedWorkout, completedWorkout.workoutId == workoutId {
            completedWorkout.routePoints = routePoints
            completedWorkout.updatedAt = updatedAt
            self.completedWorkout = completedWorkout
        }
    }

    func heartRateSamples(for workoutId: String) -> [IOSWorkoutHRSample] {
        heartRateSamplesByWorkout[workoutId] ?? []
    }

    func syncPlans(_ plans: [IOSWorkoutPlan]) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            "kind": "warbfit.phone.plans",
            "strengthPlans": plans.filter { $0.kind == .strength }.map(Self.encodeStrengthPlan),
            "swimPlans": plans.filter { $0.kind == .swim }.map(Self.encodeSwimPlan),
            "updatedAt": Date().timeIntervalSince1970,
        ]
        send(payload)
    }

    func sendActiveWorkout(_ active: IOSActiveWorkout) {
        let now = Date()
        if let lastSentActiveContextAt, now.timeIntervalSince(lastSentActiveContextAt) < 1.5 {
            return
        }
        lastSentActiveContextAt = now
        let payload: [String: Any] = [
            "kind": "warbfit.phone.workout",
            "event": "running",
            "workoutSessionId": active.id.uuidString,
            "workoutTypeId": active.type.id,
            "workoutName": active.type.name,
            "planId": active.plan?.id.uuidString ?? "",
            "planName": active.plan?.name ?? "",
            "startedAt": active.startedAt.timeIntervalSince1970,
            "elapsedSeconds": active.durationSeconds,
            "isRunning": true,
            "isPaused": false,
            "strengthSetLogs": active.strengthSetLogs.map(Self.encodeStrengthSetLog),
            "treadmillDistance": active.treadmillDistance,
            "stairFlights": active.stairFlights,
            "updatedAt": now.timeIntervalSince1970,
        ]
        send(payload)
    }

    func sendWorkoutEnded(workoutId: UUID) {
        let payload: [String: Any] = [
            "kind": "warbfit.phone.workout",
            "event": "ended",
            "workoutSessionId": workoutId.uuidString,
            "isRunning": false,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        send(payload)
    }

    private func appendHeartRateSample(workoutId: String, bpm: Int, at date: Date) {
        guard bpm >= 30, bpm <= 230 else { return }
        let ts = Int(date.timeIntervalSince1970)
        var samples = heartRateSamplesByWorkout[workoutId] ?? []
        if samples.last?.ts != ts {
            samples.append(IOSWorkoutHRSample(ts: ts, bpm: bpm))
            heartRateSamplesByWorkout[workoutId] = Array(samples.suffix(18_000))
        }
    }

    private func mergeRoutePoints(workoutId: String, incoming: [IOSRoutePoint]) -> [IOSRoutePoint] {
        guard !incoming.isEmpty else { return routePointsByWorkout[workoutId] ?? [] }
        let merged = Self.mergedRoutePoints(routePointsByWorkout[workoutId] ?? [], incoming)
        routePointsByWorkout[workoutId] = merged
        return merged
    }

    private func send(_ payload: [String: Any]) {
        guard let session else { return }
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        }
    }

    private static func encodeStrengthPlan(_ plan: IOSWorkoutPlan) -> [String: Any] {
        [
            "id": plan.id.uuidString,
            "name": plan.name,
            "exercises": plan.strengthExercises.map { exercise in
                [
                    "id": exercise.id.uuidString,
                    "name": exercise.name,
                    "sets": exercise.sets,
                    "reps": exercise.reps,
                ]
            },
        ]
    }

    private static func encodeSwimPlan(_ plan: IOSWorkoutPlan) -> [String: Any] {
        [
            "id": plan.id.uuidString,
            "name": plan.name,
            "items": plan.swimItems.map { item in
                [
                    "id": item.id.uuidString,
                    "stroke": item.stroke,
                    "sets": item.sets,
                    "distance": item.distance,
                ]
            },
        ]
    }

    private static func encodeStrengthSetLog(_ log: IOSStrengthSetLog) -> [String: Any] {
        [
            "id": log.id.uuidString,
            "exerciseId": log.exerciseId.uuidString,
            "setIndex": log.setIndex,
            "weight": log.weight,
        ]
    }

    private static func decodeStrengthSetLogs(_ rows: [[String: Any]]?) -> [IOSStrengthSetLog] {
        rows?.compactMap { row in
            guard let exerciseIdString = row["exerciseId"] as? String,
                  let exerciseId = UUID(uuidString: exerciseIdString),
                  let setIndex = row["setIndex"] as? Int else { return nil }
            return IOSStrengthSetLog(
                id: (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                exerciseId: exerciseId,
                setIndex: setIndex,
                weight: row["weight"] as? String ?? ""
            )
        } ?? []
    }

    private static func decodeRoutePoints(_ rows: [[String: Any]]?) -> [IOSRoutePoint] {
        rows?.compactMap { row in
            let ts: Int
            if let value = row["ts"] as? Int {
                ts = value
            } else if let value = row["ts"] as? Double {
                ts = Int(value)
            } else {
                return nil
            }
            guard let latitude = row["latitude"] as? Double,
                  let longitude = row["longitude"] as? Double,
                  latitude >= -90,
                  latitude <= 90,
                  longitude >= -180,
                  longitude <= 180 else { return nil }
            return IOSRoutePoint(
                ts: ts,
                latitude: latitude,
                longitude: longitude,
                altitude: row["altitude"] as? Double
            )
        } ?? []
    }

    private static func mergedRoutePoints(_ existing: [IOSRoutePoint],
                                          _ incoming: [IOSRoutePoint]) -> [IOSRoutePoint] {
        var byKey: [String: IOSRoutePoint] = [:]
        for point in existing + incoming {
            let key = "\(point.ts)-\(String(format: "%.5f", point.latitude))-\(String(format: "%.5f", point.longitude))"
            byKey[key] = point
        }
        let merged = byKey.values.sorted { $0.ts < $1.ts }
        guard merged.count > 500 else { return merged }
        let stride = max(1, merged.count / 500)
        var reduced = merged.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) ? point : nil
        }
        if reduced.last != merged.last, let last = merged.last {
            reduced.append(last)
        }
        return reduced
    }
}

extension IOSWatchWorkoutBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error {
                updateAvailability(from: session)
                activationStatus = "Companion connection failed: \(error.localizedDescription)"
            } else {
                updateAvailability(from: session)
                if activationState != .activated {
                    activationStatus = "Companion inactive"
                }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateAvailability(from: session)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateAvailability(from: session)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            apply(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            apply(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            apply(applicationContext)
        }
    }
}
