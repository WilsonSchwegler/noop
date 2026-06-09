import SwiftUI
import StrandDesign

struct IOSRootView: View {
    @EnvironmentObject private var health: IOSHealthStore
    @EnvironmentObject private var scanner: IOSWhoopScanner
    @EnvironmentObject private var workoutRecorder: IOSWorkoutRecorder
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
            scanner.refreshDeviceMetrics()
        }
        .onReceive(workoutTimer) { _ in
            workoutRecorder.record(heartRate: scanner.heartRate)
        }
    }
}
