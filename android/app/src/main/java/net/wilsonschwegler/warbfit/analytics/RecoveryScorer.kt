package net.wilsonschwegler.warbfit.analytics

import net.wilsonschwegler.warbfit.data.HrSample
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * RecoveryScorer.kt — resting HR during sleep + a transparent 0–100 recovery score.
 *
 * Faithful Kotlin port of StrandAnalytics/RecoveryScorer.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/recovery.py.
 *
 * recovery() is a z-score + logistic composite. It is APPROXIMATE — not
 * WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
 * HRV-dominant, baseline-normalized proxy.
 *
 * Weighting (documented, grounded, explainable):
 *   higher HRV vs baseline       → higher recovery  (W_HRV   = 0.60, dominant)
 *   lower resting HR vs baseline → higher recovery  (W_RHR   = 0.20)
 *   lower resp vs baseline       → higher recovery  (W_RESP  = 0.05)
 *   higher sleep performance     → higher recovery  (W_SLEEP = 0.15)
 *
 * Each metric is standardized to a robust z-score against the personal baseline
 * (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
 * renormalized. The composite z is squashed through a logistic anchored so that
 * Z = 0 → ~58% (WHOOP's published population-average recovery).
 *
 * Cold-start: if the HRV baseline (dominant driver) is not yet usable
 * (< MIN_NIGHTS_SEED valid nights), recovery() returns null. Callers may use
 * [populationMean] (58.0) as a fallback but should flag it.
 *
 * `start` / `end` are wall-clock unix SECONDS (Long), matching the net.wilsonschwegler.warbfit.data
 * layer and HrSample.ts (the Swift source uses Int seconds).
 */

/** Resting-HR estimate + transparent recovery score. Mirrors Swift `RecoveryScorer`. */
object RecoveryScorer {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (recovery.py)
    // ─────────────────────────────────────────────────────────────────────────

    const val wHRV: Double = 0.60
    const val wRHR: Double = 0.20
    const val wResp: Double = 0.05
    const val wSleep: Double = 0.15

    /** Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%). */
    const val logisticK: Double = 1.6

    /** Logistic offset so Z=0 → 58%. */
    const val logisticZ0: Double = -0.20

    /** WHOOP-published population-average recovery (%). Cold-start fallback. */
    const val populationMean: Double = 58.0

    /** Recovery band thresholds (WHOOP color scheme). */
    const val bandRedMax: Double = 34.0
    const val bandYellowMax: Double = 67.0

    /** Sleep-performance center ("good night" at ~85% efficiency). */
    const val sleepPerfCenter: Double = 0.85

    /** Sleep-performance scale (±2 z spans the normal range). */
    const val sleepPerfScale: Double = 0.12

    /** Rolling-mean HR window (seconds) for the resting-HR estimate. */
    const val restingHRWindowS: Int = 5 * 60

    // ─────────────────────────────────────────────────────────────────────────
    // Resting HR
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lowest sustained HR during the in-bed window (bpm, rounded), or null.
     *
     * "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
     * samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
     * the night's true floor. Returns null when there are no HR samples in window.
     *
     * @param start / @param end window bounds, unix SECONDS (Long).
     */
    fun restingHR(hr: List<HrSample>, start: Long, end: Long): Int? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null

        val means = ArrayList<Double>()
        var t = start
        while (t < end) {
            val binEnd = t + restingHRWindowS
            val win = seg.filter { it.ts >= t && it.ts < binEnd }
            if (win.isNotEmpty()) {
                means.add(win.sumOf { it.bpm }.toDouble() / win.size.toDouble())
            }
            t += restingHRWindowS
        }
        val floor: Double = means.minOrNull()
            ?: (seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble())
        return floor.roundToInt()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery band
    // ─────────────────────────────────────────────────────────────────────────

    /** WHOOP-style color band for a recovery score [0, 100]. */
    fun band(score: Double): String {
        if (score < bandRedMax) return "red"
        if (score < bandYellowMax) return "yellow"
        return "green"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery score
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A baseline driver: mean + spread (internal abs-dev units, as in [BaselineState]).
     * Mirrors Swift `RecoveryScorer.DriverBaseline`.
     */
    data class DriverBaseline(val mean: Double, val spread: Double) {
        constructor(state: BaselineState) : this(mean = state.baseline, spread = state.spread)
    }

    /** Robust z-score using EWMA spread: (value − mean) / (1.253 × spread). */
    internal fun zScore(value: Double, mean: Double, spread: Double): Double {
        val sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /**
     * Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
     *
     * Returns null when the HRV baseline (dominant driver) is not yet usable, or
     * no valid driver is available at all.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (raw or calibrated — z is scale-invariant);
     *   null drops the term.
     * @param hrvBaseline HRV baseline (required for a score).
     * @param rhrBaseline resting-HR baseline; null drops the RHR term.
     * @param respBaseline respiration baseline; null drops the resp term.
     * @param sleepPerf sleep-performance proxy (efficiency 0..1); null drops the term.
     * @param hrvBaselineUsable whether the HRV baseline has enough nights
     *   (BaselineState.usable). When false, returns null (cold-start).
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: DriverBaseline?,
        rhrBaseline: DriverBaseline?,
        respBaseline: DriverBaseline?,
        sleepPerf: Double?,
        hrvBaselineUsable: Boolean = true,
    ): Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if (!hrvBaselineUsable) return null

        val terms = ArrayList<Pair<Double, Double>>() // (z, weight)

        // HRV term: higher is better.
        hrvBaseline?.let { b ->
            terms.add(zScore(hrv, b.mean, b.spread) to wHRV)
        }
        // RHR term: lower is better → (μ − x) / σ.
        rhrBaseline?.let { b ->
            terms.add(zScore(b.mean, rhr, b.spread) to wRHR)
        }
        // Resp term: lower is better, optional.
        if (resp != null && respBaseline != null) {
            terms.add(zScore(respBaseline.mean, resp, respBaseline.spread) to wResp)
        }
        // Sleep-performance term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if (sleepPerf != null) {
            terms.add(((sleepPerf - sleepPerfCenter) / sleepPerfScale) to wSleep)
        }

        if (terms.isEmpty()) return null
        val totalWeight = terms.sumOf { it.second }
        if (totalWeight <= 0.0) return null

        val z = terms.sumOf { it.first * it.second } / totalWeight
        val score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /**
     * Convenience overload taking [BaselineState] directly. Enforces the cold-start
     * gate using `hrvBaseline.usable`. Mirrors the Swift `recovery(...)` overload.
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
    ): Double? = recovery(
        hrv = hrv,
        rhr = rhr,
        resp = resp,
        hrvBaseline = DriverBaseline(hrvBaseline),
        rhrBaseline = rhrBaseline?.let { DriverBaseline(it) },
        respBaseline = respBaseline?.let { DriverBaseline(it) },
        sleepPerf = sleepPerf,
        hrvBaselineUsable = hrvBaseline.usable,
    )
}
