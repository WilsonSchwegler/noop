import SwiftUI

@main
struct WarbFitWatchApp: App {
    @StateObject private var workoutManager = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchWorkoutView()
                .environmentObject(workoutManager)
        }
    }
}
