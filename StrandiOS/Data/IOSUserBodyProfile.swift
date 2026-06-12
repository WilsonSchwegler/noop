import Foundation
import StrandAnalytics

enum IOSPhysiologySex: String, CaseIterable, Identifiable {
    case notSpecified
    case female
    case male
    case other

    var id: String { rawValue }

    static var profileCases: [IOSPhysiologySex] {
        [.male, .female, .other]
    }

    var title: String {
        switch self {
        case .notSpecified: return "Not specified"
        case .female: return "Female"
        case .male: return "Male"
        case .other: return "Other"
        }
    }

    var analyticsValue: String {
        switch self {
        case .female: return "female"
        case .male: return "male"
        case .notSpecified, .other: return "nonbinary"
        }
    }
}

enum IOSTrackerWrist: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct IOSUserBodyProfile: Equatable {
    static let birthdayKey = "warbfit.profile.birthday"
    static let heightCmKey = "warbfit.profile.heightCm"
    static let weightKgKey = "warbfit.profile.weightKg"
    static let physiologySexKey = "warbfit.profile.physiologySex"
    static let trackerWristKey = "warbfit.ios.wristSide"

    var birthday: Date?
    var heightCm: Double?
    var weightKg: Double?
    var physiologySex: IOSPhysiologySex
    var trackerWrist: IOSTrackerWrist

    static var current: IOSUserBodyProfile {
        load(from: .standard)
    }

    static func load(from defaults: UserDefaults) -> IOSUserBodyProfile {
        let birthdayTime = defaults.object(forKey: birthdayKey) as? Double
        let height = positive(defaults.object(forKey: heightCmKey) as? Double)
        let weight = positive(defaults.object(forKey: weightKgKey) as? Double)
        let sexRaw = defaults.string(forKey: physiologySexKey) ?? IOSPhysiologySex.notSpecified.rawValue
        let wristRaw = defaults.string(forKey: trackerWristKey) ?? IOSTrackerWrist.left.rawValue
        return IOSUserBodyProfile(
            birthday: birthdayTime.map { Date(timeIntervalSince1970: $0) },
            heightCm: height,
            weightKg: weight,
            physiologySex: IOSPhysiologySex.fromStoredValue(sexRaw),
            trackerWrist: IOSTrackerWrist(rawValue: wristRaw) ?? .left
        )
    }

    var ageYears: Double? {
        guard let birthday else { return nil }
        let now = Date()
        guard birthday < now else { return nil }
        let days = now.timeIntervalSince(birthday) / 86_400.0
        return max(0, days / 365.2425)
    }

    var ageForHRMax: Double? {
        ageYears.flatMap { (10...100).contains($0) ? $0 : nil }
    }

    var estimatedMaxHR: Double? {
        ageForHRMax.map { StrainScorer.tanakaHRmax(age: $0) }
    }

    var analyticsProfile: UserProfile {
        UserProfile(
            weightKg: weightKg ?? 70.0,
            heightCm: heightCm ?? 170.0,
            age: ageYears ?? Double(StrainScorer.defaultAge),
            sex: physiologySex.analyticsValue
        )
    }

    var hasBodyMetrics: Bool {
        birthday != nil || heightCm != nil || weightKg != nil || physiologySex != .notSpecified
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

private extension IOSPhysiologySex {
    static func fromStoredValue(_ value: String) -> IOSPhysiologySex {
        if value == "nonbinary" { return .other }
        return IOSPhysiologySex(rawValue: value) ?? .notSpecified
    }
}
