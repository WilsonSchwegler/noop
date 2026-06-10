import SwiftUI

@main
struct StrandiOSApp: App {
    @StateObject private var scanner = IOSWhoopScanner()
    @StateObject private var health = IOSHealthStore()
    @StateObject private var workoutRecorder = IOSWorkoutRecorder()
    @StateObject private var pedometer = IOSPedometerStore()

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(scanner)
                .environmentObject(health)
                .environmentObject(workoutRecorder)
                .environmentObject(pedometer)
                .preferredColorScheme(.dark)
        }
    }
}
