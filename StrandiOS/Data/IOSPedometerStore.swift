import CoreMotion
import Foundation

@MainActor
final class IOSPedometerStore: ObservableObject {
    @Published private(set) var todaySteps: Int?
    @Published private(set) var status = CMPedometer.isStepCountingAvailable() ? "iPhone steps ready" : "iPhone steps unavailable"

    private let pedometer = CMPedometer()

    func refresh(date: Date = Date(), calendar: Calendar = .current) {
        guard CMPedometer.isStepCountingAvailable() else {
            todaySteps = nil
            status = "iPhone steps unavailable"
            return
        }
        let start = calendar.startOfDay(for: date)
        pedometer.queryPedometerData(from: start, to: date) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let steps = data?.numberOfSteps {
                    self.todaySteps = max(0, steps.intValue)
                    self.status = "iPhone steps"
                } else {
                    self.todaySteps = nil
                    self.status = error?.localizedDescription ?? "Waiting for iPhone steps"
                }
            }
        }
    }
}
