package net.wilsonschwegler.warbfit.analytics

import net.wilsonschwegler.warbfit.data.RrInterval
import kotlin.math.abs
import kotlin.math.sqrt

/*
 * HrvAnalyzer.kt — RMSSD + SDNN from RR intervals with cleaning.
 *
 * Faithful Kotlin port of StrandAnalytics/HRVAnalyzer.swift (verified on macOS).
 * The Task Force (1996) RMSSD and SDNN definitions are reproduced exactly:
 *
 *   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )           (Task Force 1996)
 *   SDNN  = sample standard deviation of NN (ddof = 1)     (Task Force 1996)
 *
 * Cleaning pipeline:
 *   1. Range filter: drop intervals outside [RR_MIN_MS, RR_MAX_MS] = [300, 2000] ms.
 *   2. Ectopic rejection: drop beats whose RR deviates > ~20% from a local median
 *      (Malik-style filter).
 *   3. Require >= MIN_BEATS (20) valid intervals before a trustworthy result.
 *
 * Named [HrvAnalyzer] (NOT Hrv) to avoid clashing with the existing
 * net.wilsonschwegler.warbfit.analytics.Hrv object in Analytics.kt. The two compute RMSSD the same
 * way (sqrt of mean successive squared diffs); HrvAnalyzer additionally cleans
 * the RR series and reports SDNN / meanNN / pNN50.
 */
object HrvAnalyzer {

    /** Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm. */
    const val RR_MIN_MS: Double = 300.0

    /** Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm. */
    const val RR_MAX_MS: Double = 2000.0

    /** Minimum valid intervals required for a trustworthy RMSSD/SDNN. */
    const val MIN_BEATS: Int = 20

    /**
     * Malik-style ectopic threshold: a beat deviating more than this fraction
     * from the local median is rejected. 0.20 == 20%.
     */
    const val ECTOPIC_THRESHOLD: Double = 0.20

    /**
     * Half-width (in beats) of the local-median window used for ectopic rejection.
     * A window of 2*radius+1 beats (5 beats at radius 2) matches the common Malik
     * moving-window implementations.
     */
    const val ECTOPIC_WINDOW_RADIUS: Int = 2

    /** Result of an HRV computation over a window. Mirrors Swift `HRVResult`. */
    data class HrvResult(
        /** RMSSD in milliseconds, or null when too few valid beats. */
        val rmssd: Double?,
        /** SDNN (sample SD, ddof=1) in milliseconds, or null when too few valid beats. */
        val sdnn: Double?,
        /** Mean NN interval (ms) over the cleaned beats, or null. */
        val meanNN: Double?,
        /** pNN50: % of successive |ΔNN| > 50 ms, or null. */
        val pnn50: Double?,
        /** Count of RR intervals supplied to the analysis (before cleaning). */
        val nInput: Int,
        /** Count of clean NN intervals after range + ectopic filtering. */
        val nClean: Int,
    ) {
        companion object {
            /** An empty/insufficient-data result that preserves the input count. */
            fun empty(nInput: Int): HrvResult =
                HrvResult(rmssd = null, sdnn = null, meanNN = null, pnn50 = null,
                    nInput = nInput, nClean = 0)
        }
    }

    // ── Primitive Task Force statistics (no filtering) ───────────────────────

    /**
     * Task Force (1996) RMSSD over already-clean NN intervals (ms). Returns null
     * when fewer than 2 values (no successive differences). No filtering applied.
     */
    fun rmssdRaw(nn: List<Double>): Double? {
        if (nn.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until nn.size) {
            val d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return sqrt(sumSq / (nn.size - 1).toDouble())
    }

    /**
     * Sample standard deviation (ddof = 1) of NN intervals (ms). Returns null for
     * fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
     */
    fun sdnnRaw(nn: List<Double>): Double? {
        if (nn.size < 2) return null
        val mean = nn.sum() / nn.size.toDouble()
        var ss = 0.0
        for (v in nn) {
            val d = v - mean
            ss += d * d
        }
        return sqrt(ss / (nn.size - 1).toDouble())
    }

    // ── Cleaning ─────────────────────────────────────────────────────────────

    /** Range filter: keep only intervals in [RR_MIN_MS, RR_MAX_MS], preserving order. */
    fun rangeFilter(rr: List<Double>): List<Double> =
        rr.filter { it >= RR_MIN_MS && it <= RR_MAX_MS }

    /**
     * Malik-style ectopic rejection: drop any beat that deviates from its local
     * median by more than [ECTOPIC_THRESHOLD] (20%). The local median is taken
     * over a centered window of `2*ECTOPIC_WINDOW_RADIUS+1` beats (excluding the
     * beat under test). Beats with too small a neighbourhood are kept.
     */
    fun rejectEctopic(nn: List<Double>): List<Double> {
        if (nn.size <= ECTOPIC_WINDOW_RADIUS) return nn
        val kept = ArrayList<Double>(nn.size)
        for (i in nn.indices) {
            val lo = maxOf(0, i - ECTOPIC_WINDOW_RADIUS)
            val hi = minOf(nn.size - 1, i + ECTOPIC_WINDOW_RADIUS)
            val neighbours = ArrayList<Double>(hi - lo)
            for (j in lo..hi) {
                if (j != i) neighbours.add(nn[j])
            }
            if (neighbours.size < 2) {
                kept.add(nn[i])
                continue
            }
            val med = median(neighbours)
            if (med <= 0) {
                kept.add(nn[i])
                continue
            }
            val deviation = abs(nn[i] - med) / med
            if (deviation <= ECTOPIC_THRESHOLD) {
                kept.add(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /** Full clean: range filter → ectopic rejection. Returns the clean NN series. */
    fun cleanRR(rr: List<Double>): List<Double> = rejectEctopic(rangeFilter(rr))

    // ── Windowed analysis ────────────────────────────────────────────────────

    /**
     * Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
     * in [windowStart, windowEnd] (inclusive). Pass null bounds to use all rows.
     *
     * Applies the range filter, Malik ectopic rejection, then requires [MIN_BEATS]
     * clean intervals; otherwise returns an empty result.
     *
     * Window bounds are unix SECONDS (Long), matching the net.wilsonschwegler.warbfit.data layer.
     */
    fun analyze(rr: List<RrInterval>, windowStart: Long? = null, windowEnd: Long? = null): HrvResult {
        val inWindow = rr.filter { sample ->
            if (windowStart != null && sample.ts < windowStart) return@filter false
            if (windowEnd != null && sample.ts > windowEnd) return@filter false
            true
        }
        val raw = inWindow.map { it.rrMs.toDouble() }
        return analyzeRaw(raw)
    }

    /**
     * Compute HRV from raw RR-interval values (ms), applying the full cleaning
     * pipeline. Returns an empty result when fewer than [MIN_BEATS] survive.
     */
    fun analyzeRaw(rawRR: List<Double>): HrvResult {
        val nInput = rawRR.size
        val clean = cleanRR(rawRR)
        if (clean.size < MIN_BEATS) {
            return HrvResult.empty(nInput)
        }
        val rmssd = rmssdRaw(clean)
        val sdnn = sdnnRaw(clean)
        val mean = clean.sum() / clean.size.toDouble()

        // pNN50 over the clean NN series.
        var nn50 = 0
        for (i in 1 until clean.size) {
            if (abs(clean[i] - clean[i - 1]) > 50.0) nn50 += 1
        }
        val pnn50 = nn50.toDouble() / (clean.size - 1).toDouble() * 100.0

        return HrvResult(rmssd = rmssd, sdnn = sdnn, meanNN = mean, pnn50 = pnn50,
            nInput = nInput, nClean = clean.size)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Median of a non-empty array. (Caller guarantees non-empty.) Returns 0.0 for
     * an empty input, matching the Swift `n == 0 → 0` guard.
     *
     * Shared with SleepStager / AnalyticsEngine ports (Swift `HRVAnalyzer.median`).
     */
    fun median(values: List<Double>): Double {
        val s = values.sorted()
        val n = s.size
        if (n == 0) return 0.0
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
