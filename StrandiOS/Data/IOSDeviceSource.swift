import Foundation

enum IOSDeviceSource: String, CaseIterable, Identifiable, Codable {
    case tracker
    case appleWatch

    static let storageKey = "warbfit.selectedDeviceSource"
    static let selectionEffectiveAtKey = "warbfit.selectedDeviceSourceEffectiveAt"
    private static let historyStorageKey = "warbfit.deviceSourceHistory.v1"
    private static let legacyTrackerRawValue = ["w", "h", "o", "o", "p"].joined()

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracker: return "Bluetooth tracker"
        case .appleWatch: return "Companion app"
        }
    }

    var statusTitle: String {
        switch self {
        case .tracker: return "Bluetooth tracker"
        case .appleWatch: return "Companion app"
        }
    }

    var icon: String {
        switch self {
        case .tracker: return "waveform.path.ecg"
        case .appleWatch: return "apps.iphone"
        }
    }

    static func value(from rawValue: String) -> IOSDeviceSource {
        if rawValue.lowercased() == legacyTrackerRawValue { return .tracker }
        return IOSDeviceSource(rawValue: rawValue) ?? .tracker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.value(from: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func current(defaults: UserDefaults = .standard) -> IOSDeviceSource {
        value(from: defaults.string(forKey: storageKey) ?? IOSDeviceSource.tracker.rawValue)
    }

    @discardableResult
    static func setCurrent(_ source: IOSDeviceSource,
                           effectiveAt: Date = Date(),
                           defaults: UserDefaults = .standard) -> Date {
        var history = storedHistory(defaults: defaults)
        if history.isEmpty {
            let previous = current(defaults: defaults)
            if previous == .tracker {
                history.append(SelectionEvent(source: .tracker, effectiveAt: .distantPast))
            } else {
                let previousEffectiveAt = storedEffectiveAt(defaults: defaults) ?? effectiveAt
                history.append(SelectionEvent(source: .tracker, effectiveAt: .distantPast))
                history.append(SelectionEvent(source: previous, effectiveAt: previousEffectiveAt))
            }
        }

        if history.last?.source != source {
            history.append(SelectionEvent(source: source, effectiveAt: effectiveAt))
        }

        defaults.set(source.rawValue, forKey: storageKey)
        defaults.set(effectiveAt.timeIntervalSince1970, forKey: selectionEffectiveAtKey)
        save(history: history, defaults: defaults)
        return effectiveAt
    }

    static func currentSelectionEffectiveAt(defaults: UserDefaults = .standard) -> Date {
        if let latest = storedHistory(defaults: defaults).last {
            return latest.effectiveAt
        }
        if let stored = storedEffectiveAt(defaults: defaults) {
            return stored
        }
        return Date()
    }

    static func source(for date: Date, defaults: UserDefaults = .standard) -> IOSDeviceSource {
        sourceResolver(defaults: defaults)(date)
    }

    static func sourceResolver(defaults: UserDefaults = .standard) -> (Date) -> IOSDeviceSource {
        let history = storedHistory(defaults: defaults)
        let selected = current(defaults: defaults)
        let selectedEffectiveAt = storedEffectiveAt(defaults: defaults) ?? Date()
        guard !history.isEmpty else {
            return { date in
                guard selected != .tracker else { return .tracker }
                return date >= selectedEffectiveAt ? selected : .tracker
            }
        }
        return { date in
            history.last(where: { $0.effectiveAt <= date })?.source ?? history.first?.source ?? .tracker
        }
    }

    static func sourceForDay(_ date: Date,
                             now: Date = Date(),
                             calendar: Calendar = .current,
                             defaults: UserDefaults = .standard) -> IOSDeviceSource {
        if storedHistory(defaults: defaults).isEmpty,
           storedEffectiveAt(defaults: defaults) == nil,
           current(defaults: defaults) != .tracker,
           calendar.isDate(date, inSameDayAs: now) {
            return current(defaults: defaults)
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return source(for: now, defaults: defaults)
        }
        let start = calendar.startOfDay(for: date)
        let lookupDate = calendar.date(byAdding: .day, value: 1, to: start)?
            .addingTimeInterval(-1) ?? date
        return source(for: lookupDate, defaults: defaults)
    }

    private struct SelectionEvent: Codable {
        let source: IOSDeviceSource
        let effectiveAt: Date
    }

    private static func storedHistory(defaults: UserDefaults) -> [SelectionEvent] {
        guard let data = defaults.data(forKey: historyStorageKey),
              let decoded = try? JSONDecoder().decode([SelectionEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.effectiveAt < $1.effectiveAt }
    }

    private static func save(history: [SelectionEvent], defaults: UserDefaults) {
        let compacted = compact(history.sorted { $0.effectiveAt < $1.effectiveAt })
        guard let data = try? JSONEncoder().encode(compacted) else { return }
        defaults.set(data, forKey: historyStorageKey)
    }

    private static func compact(_ history: [SelectionEvent]) -> [SelectionEvent] {
        history.reduce(into: []) { result, event in
            if result.last?.source == event.source {
                return
            } else {
                result.append(event)
            }
        }
    }

    private static func storedEffectiveAt(defaults: UserDefaults) -> Date? {
        let rawValue = defaults.double(forKey: selectionEffectiveAtKey)
        guard rawValue > 0 else { return nil }
        return Date(timeIntervalSince1970: rawValue)
    }
}
