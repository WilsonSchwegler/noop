import SwiftUI
import StrandDesign

struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var scanner: IOSTrackerScanner
    @EnvironmentObject private var workoutRecorder: IOSWorkoutRecorder
    @EnvironmentObject private var pedometer: IOSPedometerStore
    @EnvironmentObject private var watchWorkoutBridge: IOSWatchWorkoutBridge
    @AppStorage(IOSDeviceSource.storageKey) private var selectedDeviceSource = IOSDeviceSource.tracker.rawValue
    @State private var lastActiveWorkoutIDSentToCompanion: UUID?
    private let workoutTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ForEach(IOSFeature.allCases) { feature in
                NavigationStack {
                    FeatureDetailView(feature: feature)
                }
                .tabItem { Label(feature.rawValue, systemImage: feature.icon) }
            }
        }
        .tint(StrandPalette.accent)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task {
            scanner.setAppActive(true)
            refreshHealthAndCompanionData()
            pedometer.refresh { date, steps in
                scanner.recordPhoneSteps(steps, for: date)
            }
        }
        .onChange(of: scenePhase) { phase in
            scanner.setAppActive(phase == .active)
            if phase == .active {
                refreshHealthAndCompanionData()
                pedometer.refresh { date, steps in
                    scanner.recordPhoneSteps(steps, for: date)
                }
            }
        }
        .onChange(of: workoutRecorder.plans) { plans in
            watchWorkoutBridge.syncPlans(plans)
        }
        .onChange(of: selectedDeviceSource) { _ in
            refreshHealthAndCompanionData()
        }
        .onChange(of: watchWorkoutBridge.completedWorkoutToken) { _ in
            guard activeDeviceSource == .appleWatch else { return }
            guard let completed = watchWorkoutBridge.completedWorkout else { return }
            workoutRecorder.finishCompanionWorkout(
                completed,
                hrSamples: watchWorkoutBridge.heartRateSamples(for: completed.workoutId)
            )
            health.importRecentWorkouts(
                into: workoutRecorder,
                days: 7,
                since: IOSDeviceSource.currentSelectionEffectiveAt()
            )
        }
        .onReceive(workoutTimer) { _ in
            if activeDeviceSource == .appleWatch,
               let liveWorkout = watchWorkoutBridge.liveWorkout {
                workoutRecorder.syncCompanionWorkout(
                    liveWorkout,
                    hrSamples: watchWorkoutBridge.heartRateSamples(for: liveWorkout.workoutId)
                )
            } else if activeDeviceSource == .tracker {
                workoutRecorder.record(heartRate: scanner.heartRate)
            }

            if let active = workoutRecorder.active {
                watchWorkoutBridge.sendActiveWorkout(active)
                lastActiveWorkoutIDSentToCompanion = active.id
            } else if let workoutID = lastActiveWorkoutIDSentToCompanion {
                watchWorkoutBridge.sendWorkoutEnded(workoutId: workoutID)
                lastActiveWorkoutIDSentToCompanion = nil
            }
        }
    }

    private func refreshHealthAndCompanionData() {
        if activeDeviceSource == .appleWatch {
            health.refresh()
            health.importRecentWorkouts(
                into: workoutRecorder,
                since: IOSDeviceSource.currentSelectionEffectiveAt()
            )
        }
        watchWorkoutBridge.syncPlans(workoutRecorder.plans)
    }

    private var activeDeviceSource: IOSDeviceSource {
        IOSDeviceSource.value(from: selectedDeviceSource)
    }
}
