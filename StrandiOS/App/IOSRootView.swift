import SwiftUI
import StrandDesign

struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var workoutRecorder: IOSWorkoutRecorder
    @EnvironmentObject private var pedometer: IOSPedometerStore
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
            pedometer.refresh()
        }
        .onChange(of: scenePhase) { phase in
            scanner.setAppActive(phase == .active)
            if phase == .active {
                pedometer.refresh()
            }
        }
        .onReceive(workoutTimer) { _ in
            workoutRecorder.record(heartRate: scanner.heartRate)
        }
    }
}
