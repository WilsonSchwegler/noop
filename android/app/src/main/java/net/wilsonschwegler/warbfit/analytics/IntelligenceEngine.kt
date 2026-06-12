package net.wilsonschwegler.warbfit.analytics

import net.wilsonschwegler.warbfit.data.DailyMetric
import net.wilsonschwegler.warbfit.data.SleepSession
import net.wilsonschwegler.warbfit.data.TrackerRepository

/*
 * IntelligenceEngine.kt — on-device "intelligence": computes recovery / day-strain /
 * sleep from the raw strap streams using the same model shape TRACKER uses (HRV vs
 * personal baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0–21
 * from cardiovascular load).
 *
 * Faithful Kotlin port of Strand/Data/IntelligenceEngine.swift (verified on macOS).
 * Same windows, same thresholds, same persistence model:
 *   - For each recent day with >= MIN_HR_SAMPLES (200) HR samples, read a generous
 *     window of raw streams from the imported source ("my-tracker"), run
 *     AnalyticsEngine.analyzeDay against baselines folded from repo.days, and PERSIST
 *     the DailyMetric + sleep sessions under "<deviceId>-warbfit" (the computed source).
 *   - The repository merges these UNDER any imported "my-tracker" rows, so a real TRACKER
 *     import always wins; this only fills the days the strap collected but no import
 *     covered.
 *
 * This is what makes WarbFit independent of TRACKER's cloud — for any day the strap
 * collected raw data with WarbFit connected, WarbFit scores it itself rather than relying on
 * the values TRACKER computed in the imported CSV.
 *
 * Stateless object (no ObservableObject equivalent here): the Compose layer observes
 * the repository's reactive day flow, so this engine just computes + persists, then the
 * caller (AppViewModel) lets the flow refresh the UI. All `ts` are unix SECONDS (Long).
 */
object IntelligenceEngine {

    /** Minimum HR samples in a day's window before it is worth scoring. */
    const val MIN_HR_SAMPLES: Int = 200

    /** Read cap per stream read — matches the Swift 200_000 bound. */
    const val STREAM_LIMIT: Int = 200_000

    private const val SECONDS_PER_DAY: Long = 86_400L

    /** Summary of one scored day (for logging / a future on-device intelligence screen). */
    data class Computed(
        val day: String,
        val recovery: Double?,
        val strain: Double?,
        val sleepMin: Double?,
        val hrv: Double?,
        val rhr: Int?,
    )

    /**
     * Compute on-device scores for each of the last [maxDays] that actually has raw HR
     * data, persisting them under the computed "<importedDeviceId>-warbfit" source.
     *
     * Personal baselines (HRV / resting HR) are folded from the imported nightly history
     * (via [TrackerRepository.days]), so even the first live night can be scored against
     * the user's norm.
     *
     * @param repo the local store.
     * @param profile body profile (age/sex/weight/height + HRmax override) for HRmax,
     *   zones, calories. Defaults to a neutral [UserProfile] when the caller has none.
     * @param maxDays number of trailing days to consider (default 21).
     * @param importedDeviceId the source id the raw strap data is stored under
     *   ("my-tracker"). Computed scores are written under "<importedDeviceId>-warbfit".
     * @param maxHROverride explicit HRmax (bpm); null → Tanaka from profile.age.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests/determinism.
     * @return the per-day [Computed] summaries (newest first), mirroring the Swift `out`.
     */
    suspend fun analyzeRecent(
        repo: TrackerRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-tracker",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): List<Computed> {
        val hrvCfg = Baselines.metricCfg["hrv"] ?: return emptyList()
        val rhrCfg = Baselines.metricCfg["resting_hr"] ?: return emptyList()

        // Baselines from the imported nightly history (ascending). foldHistory winsorizes
        // outliers. days() is oldest-first, matching the Swift ascending order.
        val hist = repo.days(importedDeviceId)
        val hrvBase = Baselines.foldHistory(hist.map { it.avgHrv }, hrvCfg)
        val rhrBase = Baselines.foldHistory(hist.map { it.restingHr?.toDouble() }, rhrCfg)
        val baselines = ProfileBaselines(hrv = hrvBase, restingHR = rhrBase)

        val out = ArrayList<Computed>()
        val dailies = ArrayList<DailyMetric>()
        val sleepRows = ArrayList<SleepSession>()

        val computedId = importedDeviceId + "-warbfit"

        for (offset in 0 until maxDays) {
            val dayStart = nowSeconds - offset * SECONDS_PER_DAY
            val day = AnalyticsEngine.dayString(dayStart)
            // Read a generous window around the night that ends on `day`; the stager finds
            // the span. (30 h before, 12 h after — matches the Swift window.)
            val from = dayStart - 30 * 3_600L
            val to = dayStart + 12 * 3_600L

            val hr = repo.hrSamples(importedDeviceId, from, to, STREAM_LIMIT)
            if (hr.size < MIN_HR_SAMPLES) continue // need real raw data, not a stray sample
            val rr = repo.rrIntervals(importedDeviceId, from, to, STREAM_LIMIT)
            val resp = repo.respSamples(importedDeviceId, from, to, STREAM_LIMIT)
            val grav = repo.gravitySamples(importedDeviceId, from, to, STREAM_LIMIT)

            val res = AnalyticsEngine.analyzeDay(
                day = day,
                hr = hr,
                rr = rr,
                resp = resp,
                gravity = grav,
                profile = profile,
                baselines = baselines,
                maxHROverride = maxHROverride,
            )

            out.add(
                Computed(
                    day = day,
                    recovery = res.recovery,
                    strain = res.strain,
                    sleepMin = res.daily.totalSleepMin,
                    hrv = res.daily.avgHrv,
                    rhr = res.daily.restingHr,
                ),
            )
            // Stamp the computed source id onto the daily row (analyzeDay leaves it "").
            dailies.add(res.daily.copy(deviceId = computedId))
            // Map the rich DetectedSleep sessions → Room SleepSession cache rows.
            for (s in res.sleepSessions) {
                sleepRows.add(
                    SleepSession(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        efficiency = s.efficiency,
                        restingHr = s.restingHR,
                        avgHrv = s.avgHRV,
                        stagesJSON = AnalyticsEngine.encodeStages(s.stages),
                    ),
                )
            }
        }

        // Persist the computed scores under the dedicated "-warbfit" source so the WHOLE
        // dashboard (Today / Recovery / Strain / Sleep / Trends) reads them. The
        // repository merges these UNDER any imported "my-tracker" rows, so a real TRACKER
        // import always wins; this only fills the days the strap collected but no import
        // covered.
        if (dailies.isNotEmpty()) repo.upsertDailyMetrics(dailies)
        if (sleepRows.isNotEmpty()) repo.upsertSleepSessions(sleepRows)

        return out
    }
}
