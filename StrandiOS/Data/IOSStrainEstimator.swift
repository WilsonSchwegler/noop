import Foundation
import StrandAnalytics
import WhoopProtocol

enum IOSStrainEstimator {
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

    static func strain(hr: [HRSample],
                       gravity: [GravitySample] = [],
                       workoutTypeId: String? = nil,
                       maxHR: Double? = nil,
                       restingHR: Double? = nil) -> Double? {
        guard hr.count >= 2 else { return nil }
        _ = gravity
        let sorted = hr.sorted { $0.ts < $1.ts }
        let effectiveResting = restingHR ?? (workoutTypeId == nil ? estimatedRestingHR(from: sorted) : StrainScorer.defaultRestingHR)
        let effectiveMax = maxHR ?? StrainScorer.tanakaHRmax(age: Double(StrainScorer.defaultAge))

        return positive(StrainScorer.strain(sorted, maxHR: effectiveMax, restingHR: effectiveResting))
            ?? positive(StrainScorer.strain(sorted, maxHR: effectiveMax, restingHR: effectiveResting, method: .banister))
            ?? shortWindowStrain(sorted, maxHR: effectiveMax, restingHR: effectiveResting)
    }

    private static func estimatedRestingHR(from hr: [HRSample]) -> Double {
        let values = hr.map(\.bpm).sorted()
        guard !values.isEmpty else { return StrainScorer.defaultRestingHR }
        let index = min(values.count - 1, max(0, Int(Double(values.count - 1) * 0.10)))
        return Double(values[index])
    }

    private static func shortWindowStrain(_ hr: [HRSample],
                                          maxHR: Double,
                                          restingHR: Double) -> Double? {
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
            ?? shortWindowBanisterStrain(hr, maxHR: maxHR, restingHR: restingHR)
    }

    private static func shortWindowBanisterStrain(_ hr: [HRSample],
                                                  maxHR: Double,
                                                  restingHR: Double) -> Double? {
        guard hr.count >= 2, maxHR > restingHR else { return nil }
        let reserve = maxHR - restingHR
        var trimp = 0.0

        for index in 0..<(hr.count - 1) {
            let current = hr[index]
            let next = hr[index + 1]
            let seconds = max(1, min(60, next.ts - current.ts))
            let x = max(0, min(1, (Double(current.bpm) - restingHR) / reserve))
            if x > 0 {
                trimp += (Double(seconds) / 60.0) * x * StrainScorer.banisterScale * exp(StrainScorer.banisterBMen * x)
            }
        }

        return positive(StrainScorer.trimpToStrain(trimp))
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
