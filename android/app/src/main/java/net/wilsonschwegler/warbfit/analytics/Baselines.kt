package net.wilsonschwegler.warbfit.analytics

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/*
 * Baselines.kt — personal rolling baselines per nightly metric.
 *
 * Faithful Kotlin port of StrandAnalytics/Baselines.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/baselines.py.
 *
 * Two paths are provided:
 *   1. Winsorized EWMA (the production model): robust, recency-weighted center
 *      with an EWMA-of-absolute-deviation spread tracker, cold-start gating, hard
 *      outlier rejection, and Winsor clamping. This is [update] / [foldHistory].
 *   2. Trailing-window mean/SD (the task's "trailing 30-day mean/SD"): a simple,
 *      auditable rolling mean and sample SD over the trailing N valid nights.
 *      This is [rollingMeanSD]. Useful for explainability and cross-checking.
 *
 * Both produce a [BaselineState] so RecoveryScorer can consume either uniformly.
 *
 * The value types ([MetricCfg], [BaselineStatus], [BaselineState], [Deviation])
 * are defined in AnalyticsModels.kt and intentionally NOT redefined here. All
 * `ts` are wall-clock unix SECONDS (Long) elsewhere; baselines work on per-night
 * scalar values and carry no timestamps.
 *
 * Outputs are APPROXIMATE and not medical advice.
 */

/** Personal rolling baselines. Mirrors Swift `Baselines` (an enum used as a namespace). */
object Baselines {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (baselines.py)
    // ─────────────────────────────────────────────────────────────────────────

    /** Winsorization clamp: fold only within ±WINSOR_K × spread. */
    const val winsorK: Double = 3.0

    /** Hard-reject gate: drop the night if > HARD_OUTLIER_K × spread away. */
    const val hardOutlierK: Double = 5.0

    /** Minimum valid nights before "provisionally" trusted. */
    const val minNightsSeed: Int = 4

    /** Minimum valid nights before fully trusted. */
    const val minNightsTrust: Int = 14

    /** Missing-night count after which a baseline is marked stale. */
    const val staleDays: Int = 14

    /** Default per-metric configurations (HRV, resting HR, respiration, skin temp). */
    val metricCfg: Map<String, MetricCfg> = mapOf(
        "hrv" to MetricCfg(
            minVal = 5.0, maxVal = 250.0, floorSpread = 5.0,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "resting_hr" to MetricCfg(
            minVal = 30.0, maxVal = 120.0, floorSpread = 2.0,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "resp" to MetricCfg(
            minVal = 4.0, maxVal = 40.0, floorSpread = 0.5,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
        "skin_temp" to MetricCfg(
            minVal = 20.0, maxVal = 42.0, floorSpread = 0.3,
            halfLifeB = 14.0, halfLifeS = 21.0,
        ),
    )

    /** Convenience accessor for the standard HRV config. */
    val hrvCfg: MetricCfg get() = metricCfg.getValue("hrv")

    /** Convenience accessor for the standard resting-HR config. */
    val restingHRCfg: MetricCfg get() = metricCfg.getValue("resting_hr")

    /** Convenience accessor for the standard respiration config. */
    val respCfg: MetricCfg get() = metricCfg.getValue("resp")

    /** Convert a half-life in nights to an EWMA smoothing factor. */
    internal fun lambda(halfLife: Double): Double = 1.0 - 0.5.pow(1.0 / halfLife)

    internal fun computeStatus(nValid: Int, nightsSinceUpdate: Int): BaselineStatus {
        if (nightsSinceUpdate > staleDays && nValid >= minNightsSeed) return BaselineStatus.STALE
        if (nValid < minNightsSeed) return BaselineStatus.CALIBRATING
        if (nValid < minNightsTrust) return BaselineStatus.PROVISIONAL
        return BaselineStatus.TRUSTED
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Winsorized EWMA update (production model)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Incorporate one new nightly value into the baseline state.
     *
     * - `state == null`: seed the first night.
     * - `value == null` or out-of-range: skip-and-hold (carry forward).
     * - hard outlier (> HARD_OUTLIER_K × spread): seen but not folded.
     * - otherwise: Winsorized EWMA center + EWMA-abs-dev spread update.
     */
    fun update(state: BaselineState?, value: Double?, cfg: MetricCfg): BaselineState {
        val lb = lambda(cfg.halfLifeB)
        val ls = lambda(cfg.halfLifeS)

        // First night ever.
        if (state == null) {
            if (value != null && cfg.minVal <= value && value <= cfg.maxVal) {
                return BaselineState(
                    baseline = value, spread = cfg.floorSpread, nValid = 1,
                    nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
                )
            }
            val seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(
                baseline = seed, spread = cfg.floorSpread, nValid = 0,
                nightsSinceUpdate = 1, status = BaselineStatus.CALIBRATING,
            )
        }

        // Missing night: skip-and-hold.
        if (value == null) {
            val m = state.nightsSinceUpdate + 1
            return BaselineState(
                baseline = state.baseline, spread = state.spread,
                nValid = state.nValid, nightsSinceUpdate = m,
                status = computeStatus(state.nValid, m),
            )
        }

        // Step 0: sanity gate — physiologically implausible → skip-and-hold.
        if (!(cfg.minVal <= value && value <= cfg.maxVal)) {
            val m = state.nightsSinceUpdate + 1
            return BaselineState(
                baseline = state.baseline, spread = state.spread,
                nValid = state.nValid, nightsSinceUpdate = m,
                status = computeStatus(state.nValid, m),
            )
        }

        // Hard outlier rejection (only once seeded): seen, but not folded.
        if (state.nValid >= minNightsSeed) {
            val dev = abs(value - state.baseline)
            if (dev > hardOutlierK * state.spread) {
                return BaselineState(
                    baseline = state.baseline, spread = state.spread,
                    nValid = state.nValid, nightsSinceUpdate = 0,
                    status = computeStatus(state.nValid, 0),
                )
            }
        }

        // First real value after a None-placeholder seed: treat as clean first night.
        if (state.nValid == 0) {
            return BaselineState(
                baseline = value, spread = cfg.floorSpread, nValid = 1,
                nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
            )
        }

        // Step 1: Winsorized EWMA update.
        val lo = state.baseline - winsorK * state.spread
        val hi = state.baseline + winsorK * state.spread
        val clamped = max(lo, min(hi, value))
        val newBaseline = lb * clamped + (1.0 - lb) * state.baseline

        // Spread uses the UNCLAMPED value so true deviations are tracked.
        val absDev = abs(value - newBaseline)
        val newSpread = max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread)
        val newN = state.nValid + 1

        return BaselineState(
            baseline = newBaseline, spread = newSpread, nValid = newN,
            nightsSinceUpdate = 0,
            status = computeStatus(newN, 0),
        )
    }

    /**
     * Replay an ordered sequence of nightly values (oldest first) to build state.
     * `null` entries are treated as missing nights (skip-and-hold).
     */
    fun foldHistory(values: List<Double?>, cfg: MetricCfg): BaselineState {
        var state: BaselineState? = null
        for (v in values) state = update(state, v, cfg)
        state?.let { return it }
        val seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(
            baseline = seed, spread = cfg.floorSpread, nValid = 0,
            nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deviation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Compute z / delta / ratio / in-normal-range for a value vs a baseline.
     * z uses (value − baseline) / (1.253 × spread); 1.253 converts EWMA-abs-dev
     * to an approximate Gaussian σ (E[|X−μ|] = σ·√(2/π) ≈ σ/1.253).
     */
    fun deviation(value: Double, state: BaselineState): Deviation {
        val sigma = max(1.253 * state.spread, 1e-9)
        val z = (value - state.baseline) / sigma
        val delta = value - state.baseline
        val ratio = if (state.baseline != 0.0) (value / state.baseline - 1.0) else 0.0
        return Deviation(z = z, delta = delta, ratio = ratio, inNormalRange = abs(z) <= 1.0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trailing-window mean/SD (simple, auditable)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Rolling personal baseline from the trailing [window] valid nights, as a
     * plain mean and sample SD (ddof=1). This is the task's "trailing 30-day
     * mean/SD" path: no recency weighting, maximally explainable.
     *
     * Physiologically implausible values (outside cfg bounds) and nulls are
     * dropped. The spread returned is stored in the SAME internal units the
     * Winsor EWMA uses (abs-dev space), i.e. SD / 1.253, so that [deviation]
     * recovers the intended Gaussian σ unchanged.
     *
     * @param values ordered nightly values (oldest → newest); nulls allowed.
     * @param cfg metric config (bounds + floor spread).
     * @param window number of trailing valid nights to use (default 30).
     */
    fun rollingMeanSD(values: List<Double?>, cfg: MetricCfg, window: Int = 30): BaselineState {
        val valid = values.mapNotNull { v ->
            if (v != null && cfg.minVal <= v && v <= cfg.maxVal) v else null
        }
        if (valid.isEmpty()) {
            val seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(
                baseline = seed, spread = cfg.floorSpread, nValid = 0,
                nightsSinceUpdate = 0, status = BaselineStatus.CALIBRATING,
            )
        }
        val trailing = valid.takeLast(window)
        val n = trailing.size
        val mean = trailing.sum() / n.toDouble()

        val sd: Double
        if (n >= 2) {
            var ss = 0.0
            for (v in trailing) {
                val d = v - mean
                ss += d * d
            }
            sd = sqrt(ss / (n - 1).toDouble())
        } else {
            // Single sample: no dispersion estimate; fall back to the σ floor.
            sd = cfg.floorSpread * 1.253
        }

        // Apply the σ floor in σ-space, then convert to internal abs-dev space.
        val sigmaFloored = max(cfg.floorSpread, sd)
        val spreadInternal = sigmaFloored / 1.253

        return BaselineState(
            baseline = mean, spread = spreadInternal, nValid = n,
            nightsSinceUpdate = 0,
            status = computeStatus(n, 0),
        )
    }
}
