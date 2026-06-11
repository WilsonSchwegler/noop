package net.wilsonschwegler.warbfit.analytics

import net.wilsonschwegler.warbfit.data.HrSample
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToLong

/*
 * StrainScorer.kt — cardiovascular load on a 0–21 logarithmic strain scale.
 *
 * Faithful Kotlin port of StrandAnalytics/StrainScorer.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation
 * of published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
 * proprietary algorithm; not medical advice).
 *
 * Pipeline:
 *   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
 *   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
 *   3. TRIMP accumulated over the window:
 *        a. Edwards 5-zone summation (default): sample contributes its zone weight
 *           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
 *        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
 *   4. Logarithmic compression onto [0, 21]:
 *        strain = 21 × ln(TRIMP + 1) / ln(D),  D = STRAIN_DENOMINATOR.
 *
 * References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
 * (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).
 *
 * Operates on the Room [HrSample] (ts:Long unix seconds, bpm:Int). The HRR-based
 * zone math here is INDEPENDENT of the %HRmax display zones in [HrZones]; this port
 * uses [HrZones] only where the Swift used HRZones (none in this file — strain has
 * its own Edwards %HRR thresholds).
 */
object StrainScorer {

    // ---- Constants (strain.py) ----

    /** Minimum HR readings before computing strain (≈10 min at 1 Hz). */
    const val minReadings: Int = 600

    /** Top of the strain scale. */
    const val maxStrain: Double = 21.0

    /**
     * Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
     * (top zone weight 5 sustained 24 h = 7200) maps to exactly 21.0:
     * D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
     */
    const val strainDenominator: Double = 7201.0
    val lnStrainDenominator: Double get() = ln(strainDenominator)

    /** Fallback per-sample duration (minutes) — 1 s at 1 Hz. */
    const val fallbackSampleMin: Double = 1.0 / 60.0

    const val defaultAge: Int = 30
    const val defaultRestingHR: Double = 60.0

    /** Minimum HR samples before the observed high-percentile HRmax is trusted. */
    const val hrmaxMinSamples: Int = 600

    /** Upper percentile for the observed-HRmax estimate. */
    const val hrmaxPercentile: Double = 99.5

    /** Banister coefficients. */
    const val banisterScale: Double = 0.64
    const val banisterBMen: Double = 1.92
    const val banisterBWomen: Double = 1.67

    /** Edwards zone cut-offs as (%HRR threshold, weight), highest-first. */
    val edwardsZones: List<Pair<Double, Int>> = listOf(
        90.0 to 5, 80.0 to 4, 70.0 to 3, 60.0 to 2, 50.0 to 1,
    )

    /** TRIMP accumulation method. */
    enum class Method { EDWARDS, BANISTER }

    /** Strain calibration / fit errors. Mirrors Swift `StrainError`. */
    enum class StrainError { TOO_FEW_PAIRS, DEGENERATE }

    /** Thrown by [fitStrainDenominator] when the fit is impossible. */
    class StrainException(val error: StrainError) : Exception("Strain fit failed: $error")

    // ---- HRmax helpers ----

    /** Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent). */
    fun tanakaHRmax(age: Double): Double = 208.0 - 0.7 * age

    /** Classic 220 − age. Last-resort fallback only. */
    fun defaultMaxHR(age: Int = defaultAge): Int = 220 - age

    /** Linear-interpolated percentile of an already-sorted sequence (numpy-style). */
    fun percentile(sortedValues: List<Double>, pct: Double): Double {
        val n = sortedValues.size
        if (n == 0) return 0.0
        if (n == 1) return sortedValues[0]
        val position = (pct / 100.0) * (n - 1).toDouble()
        val lower = position.toInt()
        val upper = minOf(lower + 1, n - 1)
        val frac = position - lower.toDouble()
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /**
     * Estimate a personalized HRmax from a trailing HR series.
     * Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
     */
    fun estimateHRmax(hrHistory: List<Double>, age: Double?): Pair<Double, String> {
        val n = hrHistory.size
        val tanaka = age?.let { tanakaHRmax(it) }

        if (n >= hrmaxMinSamples) {
            val observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            if (tanaka == null) return observed to "observed"
            return if (observed >= tanaka) observed to "observed" else tanaka to "tanaka"
        }
        if (tanaka != null) return tanaka to "tanaka"
        return 0.0 to "unknown"
    }

    // ---- Karvonen %HRR and Edwards zone weight ----

    /** Karvonen %HRR, clamped [0, 100]. */
    fun pctHRR(bpm: Double, restingHR: Double, hrReserve: Double): Double {
        val pct = (bpm - restingHR) / hrReserve * 100.0
        if (pct < 0) return 0.0
        if (pct > 100) return 100.0
        return pct
    }

    /**
     * Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
     * the clamped path at both ends).
     */
    fun zoneWeight(bpm: Double, restingHR: Double, hrReserve: Double): Int {
        val pct = (bpm - restingHR) / hrReserve * 100.0
        for ((threshold, weight) in edwardsZones) {
            if (pct >= threshold) return weight
        }
        return 0
    }

    // ---- TRIMP accumulation ----

    /**
     * Infer per-sample duration (minutes) from the first two timestamps. Falls
     * back to 1 s when fewer than two samples or coincident timestamps.
     */
    fun sampleDurationMinutes(hr: List<HrSample>): Double {
        if (hr.size < 2) return fallbackSampleMin
        val deltaS = abs((hr[1].ts - hr[0].ts).toDouble())
        return if (deltaS > 0) deltaS / 60.0 else fallbackSampleMin
    }

    fun edwardsTRIMP(
        hr: List<HrSample>,
        restingHR: Double,
        hrReserve: Double,
        sampleDurationMin: Double,
    ): Double {
        var weighted = 0
        for (s in hr) {
            weighted += zoneWeight(s.bpm.toDouble(), restingHR, hrReserve)
        }
        return weighted.toDouble() * sampleDurationMin
    }

    fun banisterTRIMP(
        hr: List<HrSample>,
        restingHR: Double,
        hrReserve: Double,
        sampleDurationMin: Double,
        b: Double,
    ): Double {
        var acc = 0.0
        for (s in hr) {
            val x = pctHRR(s.bpm.toDouble(), restingHR, hrReserve) / 100.0
            if (x > 0) acc += sampleDurationMin * x * banisterScale * exp(b * x)
        }
        return acc
    }

    // ---- Logarithmic map ----

    /**
     * Map accumulated TRIMP onto [0, 21] via 21 × ln(TRIMP+1) / ln(D), 2 dp.
     * TRIMP ≤ 0 → 0.
     */
    fun trimpToStrain(trimp: Double, denominator: Double = strainDenominator): Double {
        if (trimp <= 0) return 0.0
        val value = maxStrain * ln(trimp + 1.0) / ln(denominator)
        return (value * 100).roundToLong() / 100.0
    }

    // ---- Denominator calibration ----

    /**
     * Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
     * least-squares line: ln(D) = 21 × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
     * Throws [StrainException] when fewer than 2 usable pairs (TRIMP>0, strain>0)
     * or degenerate.
     */
    fun fitStrainDenominator(pairs: List<Pair<Double, Double>>): Double {
        val usable = pairs.filter { it.first > 0 && it.second > 0 }
        if (usable.size < 2) throw StrainException(StrainError.TOO_FEW_PAIRS)
        var sumXX = 0.0
        var sumXY = 0.0
        for ((trimp, strain) in usable) {
            val x = ln(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        if (!(sumXY > 0 && sumXX > 0)) throw StrainException(StrainError.DEGENERATE)
        return exp(maxStrain * sumXX / sumXY)
    }

    // ---- Public API ----

    /**
     * Cardiovascular strain (0–21) from an HR series. APPROXIMATE.
     *
     * Returns null when there are fewer than [minReadings] samples or
     * maxHR ≤ restingHR (invalid HRR).
     *
     * @param hr time-ordered [HrSample] list.
     * @param maxHR HRmax (bpm). Defaults to 220 − defaultAge when null.
     * @param restingHR resting HR (bpm) for the HRR denominator (default 60).
     * @param method [Method.EDWARDS] (default) or [Method.BANISTER].
     * @param sex "male"/"female" — selects the Banister coefficient (ignored by Edwards).
     * @param denominator log-map D (default [strainDenominator]).
     */
    fun strain(
        hr: List<HrSample>,
        maxHR: Double? = null,
        restingHR: Double = defaultRestingHR,
        method: Method = Method.EDWARDS,
        sex: String = "male",
        denominator: Double = strainDenominator,
    ): Double? {
        val effMax = maxHR ?: defaultMaxHR().toDouble()
        if (hr.size < minReadings || effMax <= restingHR) return null

        val sampleDur = sampleDurationMinutes(hr)
        val hrReserve = effMax - restingHR

        val trimp: Double = when (method) {
            Method.BANISTER -> {
                val b = if (sex.lowercase().startsWith("f")) banisterBWomen else banisterBMen
                banisterTRIMP(hr, restingHR, hrReserve, sampleDur, b)
            }
            Method.EDWARDS -> {
                edwardsTRIMP(hr, restingHR, hrReserve, sampleDur)
            }
        }
        return trimpToStrain(trimp, denominator)
    }
}
