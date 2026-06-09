import SwiftUI
import StrandDesign

enum IOSFeature: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case workouts = "Workouts"
    case live = "Status"
    case more = "More"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .workouts: return "list.bullet.clipboard.fill"
        case .live: return "waveform.path.ecg"
        case .more: return "ellipsis"
        }
    }

    var accent: Color {
        switch self {
        case .today, .live: return StrandPalette.accent
        case .workouts: return StrandPalette.strain066
        case .more: return StrandPalette.metricPurple
        }
    }
}
