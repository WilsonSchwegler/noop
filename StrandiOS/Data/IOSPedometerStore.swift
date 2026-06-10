import CoreMotion
import Foundation

@MainActor
final class IOSPedometerStore: ObservableObject {
    @Published private(set) var todaySteps: Int?
    @Published private(set) var displayedSteps: Int?
    @Published private(set) var displayedDate = Date()
    @Published private(set) var status = CMPedometer.isStepCountingAvailable() ? "iPhone steps ready" : "iPhone steps unavailable"

    private let pedometer = CMPedometer()

    func refresh(date: Date = Date(),
                 calendar: Calendar = .current,
                 onUpdate: (@MainActor (Date, Int) -> Void)? = nil) {
        displayedDate = date
        guard CMPedometer.isStepCountingAvailable() else {
            if calendar.isDateInToday(date) {
                todaySteps = nil
            }
            displayedSteps = nil
            status = "iPhone steps unavailable"
            return
        }
        let start = calendar.startOfDay(for: date)
        let end = calendar.isDateInToday(date)
            ? Date()
            : (calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? date)
        pedometer.queryPedometerData(from: start, to: end) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                guard calendar.isDate(self.displayedDate, inSameDayAs: date) else { return }
                if let steps = data?.numberOfSteps {
                    let count = max(0, steps.intValue)
                    if calendar.isDateInToday(date) {
                        self.todaySteps = count
                    }
                    self.displayedSteps = count
                    self.status = "iPhone steps"
                    onUpdate?(date, count)
                } else {
                    if calendar.isDateInToday(date) {
                        self.todaySteps = nil
                    }
                    self.displayedSteps = nil
                    self.status = error?.localizedDescription ?? "Waiting for iPhone steps"
                }
            }
        }
    }
}
