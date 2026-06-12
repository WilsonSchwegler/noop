import Foundation
import StrandAnalytics
import TrackerProtocol

enum IOSStrainEstimator {
    /// ACSM/Norton intensity terminology places light effort around 30% HRR
    /// and moderate effort around 40% HRR. Daily strain combines a very small
    /// quiet-awake load with HRR/TRIMP load once HR rises into light intensity.
    private static let dailyLightIntensityFloorHRR = 0.30
    private static let dailyModerateIntensityFloorHRR = 0.40

    /// Compendium MET anchors: sleep is slightly below 1 MET, quiet wakefulness
    /// is about 1 MET, and moderate activity starts around 3 METs.
    private static let sleepingMET = 0.95
    private static let quietAwakeMET = 1.0
    private static let moderateActivityMET = 3.0
    private static let exertionRestingHRKeyPrefix = "warbfit.exertion.restingHRBaseline."
    private static let validRestingHRRange = 30.0...120.0

    static func combine(_ strains: [Double]) -> Double? {
        let valid = strains.filter { $0 > 0 }
        guard !valid.isEmpty else { return nil }
        let totalLoad = valid.reduce(0.0) { $0 + trimp(fromStrain: $1) }
        return StrainScorer.trimpToStrain(totalLoad)
    }

    static func recoveryAdjustedLoad(strain: Double?, recovery: Double?) -> Double? {
        guard let strain, strain > 0, let recovery, recovery.isFinite else { return nil }
        let capacity = recoveryCapacity(for: recovery)
        guard capacity > 0 else { return nil }
        return StrainScorer.trimpToStrain(trimp(fromStrain: strain) / capacity)
    }

    /// Resting HR for exertion is a calibration input for HR reserve, so prefer a
    /// stable personal baseline over one noisy night or a same-day low percentile.
    static func exertionRestingHR(baseline: Double? = nil,
                                  recentRestingHR: Double? = nil,
                                  samples: [HRSample] = [],
                                  source: IOSDeviceSource? = nil) -> Double {
        if let baseline = sanitizedRestingHR(baseline) { return baseline }
        if let source, let cached = cachedExertionRestingHR(for: source) { return cached }
        if source == nil, let cached = cachedExertionRestingHR(for: IOSDeviceSource.current()) { return cached }
        if let recent = sanitizedRestingHR(recentRestingHR) { return recent }
        if !samples.isEmpty { return estimatedRestingHR(from: samples) }
        return StrainScorer.defaultRestingHR
    }

    static func saveExertionRestingHRBaseline(_ restingHR: Double?, for source: IOSDeviceSource) {
        guard let restingHR = sanitizedRestingHR(restingHR) else { return }
        UserDefaults.standard.set(restingHR, forKey: exertionRestingHRKey(for: source))
    }

    static func cachedExertionRestingHR(for source: IOSDeviceSource) -> Double? {
        let value = UserDefaults.standard.double(forKey: exertionRestingHRKey(for: source))
        return sanitizedRestingHR(value)
    }

    static func strain(hr: [HRSample],
                       gravity: [GravitySample] = [],
                       workoutTypeId: String? = nil,
                       maxHR: Double? = nil,
                       restingHR: Double? = nil,
                       physiologySex: String = "nonbinary") -> Double? {
        guard hr.count >= 2 else { return nil }
        _ = gravity
        let sorted = hr.sorted { $0.ts < $1.ts }
        let effectiveResting = restingHR
            ?? cachedExertionRestingHR(for: IOSDeviceSource.current())
            ?? (workoutTypeId == nil ? estimatedRestingHR(from: sorted) : StrainScorer.defaultRestingHR)
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))

        return positive(StrainScorer.strain(sorted, maxHR: effectiveMax, restingHR: effectiveResting))
            ?? shortWindowStrain(sorted, maxHR: effectiveMax, restingHR: effectiveResting, physiologySex: physiologySex)
    }

    static func strain(metricSamples: [IOSMetricHRSample]) -> Double? {
        strain(hr: metricSamples.map { HRSample(ts: $0.ts, bpm: $0.bpm) })
    }

    static func awakeDayStrain(metricSamples: [IOSMetricHRSample],
                               maxHR: Double? = nil,
                               restingHR: Double? = nil,
                               physiologySex: String = "nonbinary") -> Double? {
        let hr = metricSamples.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        return awakeDayStrain(hr: hr, maxHR: maxHR, restingHR: restingHR, physiologySex: physiologySex)
    }

    static func awakeDayStrain(hr: [HRSample],
                               maxHR: Double? = nil,
                               restingHR: Double? = nil,
                               physiologySex: String = "nonbinary") -> Double? {
        let sorted = hr
            .filter { $0.bpm >= 30 && $0.bpm <= 220 }
            .sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return nil }
        let effectiveResting = restingHR
            ?? cachedExertionRestingHR(for: IOSDeviceSource.current())
            ?? estimatedRestingHR(from: sorted)
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))
        return intervalAwareDailyStrain(sorted, maxHR: effectiveMax, restingHR: effectiveResting, physiologySex: physiologySex)
    }

    private static func estimatedRestingHR(from hr: [HRSample]) -> Double {
        let values = hr.map(\.bpm).sorted()
        guard !values.isEmpty else { return StrainScorer.defaultRestingHR }
        let index = min(values.count - 1, max(0, Int(Double(values.count - 1) * 0.10)))
        return sanitizedRestingHR(Double(values[index])) ?? StrainScorer.defaultRestingHR
    }

    private static func sanitizedRestingHR(_ value: Double?) -> Double? {
        guard let value, value.isFinite, validRestingHRRange.contains(value) else { return nil }
        return value
    }

    private static func exertionRestingHRKey(for source: IOSDeviceSource) -> String {
        exertionRestingHRKeyPrefix + source.rawValue
    }

    private static func shortWindowStrain(_ hr: [HRSample],
                                          maxHR: Double,
                                          restingHR: Double,
                                          physiologySex: String) -> Double? {
        guard hr.count >= 2, maxHR > restingHR else { return nil }
        let reserve = maxHR - restingHR
        var trimp = 0.0

        for index in 0..<(hr.count - 1) {
            let current = hr[index]
            let next = hr[index + 1]
            let seconds = max(1, min(60, next.ts - current.ts))
            let pctHRR = max(0, min(1, (Double(current.bpm) - restingHR) / reserve))
            trimp += Double(edwardsWeight(for: pctHRR)) * Double(seconds) / 60.0
        }

        return positive(StrainScorer.trimpToStrain(trimp))
            ?? shortWindowBanisterStrain(hr, maxHR: maxHR, restingHR: restingHR, physiologySex: physiologySex)
    }

    private static func shortWindowBanisterStrain(_ hr: [HRSample],
                                                  maxHR: Double,
                                                  restingHR: Double,
                                                  physiologySex: String) -> Double? {
        guard hr.count >= 2, maxHR > restingHR else { return nil }
        let reserve = maxHR - restingHR
        var trimp = 0.0

        for index in 0..<(hr.count - 1) {
            let current = hr[index]
            let next = hr[index + 1]
            let seconds = max(1, min(60, next.ts - current.ts))
            let x = max(0, min(1, (Double(current.bpm) - restingHR) / reserve))
            if x > 0 {
                let b = banisterCoefficient(for: physiologySex)
                trimp += (Double(seconds) / 60.0) * x * StrainScorer.banisterScale * exp(b * x)
            }
        }

        return positive(StrainScorer.trimpToStrain(trimp))
    }

    private static func intervalAwareDailyStrain(_ sorted: [HRSample],
                                                 maxHR: Double,
                                                 restingHR: Double,
                                                 physiologySex: String) -> Double? {
        guard sorted.count >= 2 else { return nil }
        guard maxHR > restingHR else { return nil }
        let reserve = maxHR - restingHR
        var trimp = 0.0

        for index in 0..<(sorted.count - 1) {
            let current = sorted[index]
            let next = sorted[index + 1]
            let seconds = max(1, min(60, next.ts - current.ts))
            let minutes = Double(seconds) / 60.0
            trimp += minutes * quietAwakeTRIMPPerMinute
            let x = max(0, min(1, (Double(current.bpm) - restingHR) / reserve))
            guard x >= dailyLightIntensityFloorHRR else { continue }
            let edwards = Double(edwardsWeight(for: x))
            let dailyX = (x - dailyLightIntensityFloorHRR) / (1.0 - dailyLightIntensityFloorHRR)
            let b = banisterCoefficient(for: physiologySex)
            let banister = dailyX * StrainScorer.banisterScale * exp(b * dailyX)
            trimp += minutes * max(edwards, banister)
        }

        guard trimp.isFinite else { return nil }
        return StrainScorer.trimpToStrain(trimp)
    }

    private static var quietAwakeTRIMPPerMinute: Double {
        let moderateX = (dailyModerateIntensityFloorHRR - dailyLightIntensityFloorHRR) / (1.0 - dailyLightIntensityFloorHRR)
        let moderateLoad = moderateX * StrainScorer.banisterScale * exp(neutralBanisterCoefficient * moderateX)
        let metFraction = (quietAwakeMET - sleepingMET) / (moderateActivityMET - sleepingMET)
        return max(0, moderateLoad * metFraction)
    }

    private static var neutralBanisterCoefficient: Double {
        (StrainScorer.banisterBMen + StrainScorer.banisterBWomen) / 2.0
    }

    private static func banisterCoefficient(for physiologySex: String) -> Double {
        switch physiologySex.lowercased() {
        case let sex where sex.hasPrefix("f"):
            return StrainScorer.banisterBWomen
        case let sex where sex.hasPrefix("m"):
            return StrainScorer.banisterBMen
        default:
            return neutralBanisterCoefficient
        }
    }

    private static func edwardsWeight(for pctHRR: Double) -> Int {
        switch pctHRR {
        case 0.90...: return 5
        case 0.80..<0.90: return 4
        case 0.70..<0.80: return 3
        case 0.60..<0.70: return 2
        case 0.50..<0.60: return 1
        default: return 0
        }
    }

    private static func trimp(fromStrain strain: Double) -> Double {
        let clamped = min(StrainScorer.maxStrain, max(0, strain))
        return exp((clamped / StrainScorer.maxStrain) * log(StrainScorer.strainDenominator)) - 1
    }

    private static func recoveryCapacity(for recovery: Double) -> Double {
        let clamped = min(100.0, max(0.0, recovery))
        if clamped >= RecoveryScorer.bandYellowMax { return 1.0 }
        if clamped >= RecoveryScorer.bandRedMax {
            let t = (clamped - RecoveryScorer.bandRedMax) / (RecoveryScorer.bandYellowMax - RecoveryScorer.bandRedMax)
            return 0.80 + 0.20 * t
        }
        let t = clamped / RecoveryScorer.bandRedMax
        return 0.60 + 0.20 * t
    }

    private static func positive(_ strain: Double?) -> Double? {
        guard let strain, strain > 0 else { return nil }
        return strain
    }
}
