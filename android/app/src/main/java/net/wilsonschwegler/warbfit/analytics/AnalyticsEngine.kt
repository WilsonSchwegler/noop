package net.wilsonschwegler.warbfit.analytics

import net.wilsonschwegler.warbfit.data.DailyMetric
import net.wilsonschwegler.warbfit.data.GravitySample
import net.wilsonschwegler.warbfit.data.HrSample
import net.wilsonschwegler.warbfit.data.RespSample
import net.wilsonschwegler.warbfit.data.RrInterval
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/*
 * AnalyticsEngine.kt — orchestrator producing DailyMetric + sleep-session results.
 *
 * Faithful Kotlin port of StrandAnalytics/AnalyticsEngine.swift (verified on macOS).
 * Same algorithm, same constants, same thresholds; Kotlin-ized types, Double math.
 *
 * Given a day's raw streams + a user profile + personal baselines, it runs the
 * individual analyzers (SleepStager / RecoveryScorer / StrainScorer / WorkoutDetector
 * / Baselines) and assembles a [net.wilsonschwegler.warbfit.data.DailyMetric] (Room cache shape) plus the
 * detected [DetectedSleep] sessions.
 *
 * This is a PURE function over its inputs — it does NOT touch the database
 * (persistence is wired by IntelligenceEngine). All derived values are APPROXIMATE.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); the Swift source
 * uses Int seconds.
 */
object AnalyticsEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // Day-string helper (UTC YYYY-MM-DD), mirrors Swift AnalyticsEngine.isoDay.
    // ─────────────────────────────────────────────────────────────────────────

    private val isoDay: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

    /** Format a unix-seconds timestamp as a UTC YYYY-MM-DD day string. */
    fun dayString(ts: Long): String = isoDay.format(Instant.ofEpochSecond(ts))

    /**
     * JSON-encode stage segments to the verbatim array shape the sleepSession cache
     * stores. Mirrors Swift `encodeStages` (JSONEncoder on [StageSegment]); the field
     * order/names (start, end, stage) match the Codable wire shape and the Android
     * SleepScreen reader.
     */
    fun encodeStages(stages: List<StageSegment>): String? {
        return try {
            val arr = JSONArray()
            for (s in stages) {
                val o = JSONObject()
                o.put("start", s.start)
                o.put("end", s.end)
                o.put("stage", s.stage)
                arr.put(o)
            }
            arr.toString()
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Analyze one day's streams into a [DayResult].
     *
     * @param day the calendar day (UTC) this metric is for; a sleep session is
     *   attributed to the day its `end` falls on (a night ending that morning).
     * @param hr/rr/resp/gravity the day's raw streams (the wider window around the
     *   night may be passed; sleep detection finds the in-bed span itself).
     * @param profile user profile (age/sex/weight/height) for HRmax + calories.
     * @param baselines personal baselines for recovery normalization.
     * @param maxHROverride explicit HRmax (bpm) to use for strain/zones; null →
     *   Tanaka from profile.age.
     */
    fun analyzeDay(
        day: String,
        hr: List<HrSample> = emptyList(),
        rr: List<RrInterval> = emptyList(),
        resp: List<RespSample> = emptyList(),
        gravity: List<GravitySample> = emptyList(),
        profile: UserProfile,
        baselines: ProfileBaselines = ProfileBaselines(),
        maxHROverride: Double? = null,
    ): DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        val allSessions = SleepStager.detectSleep(hr = hr, rr = rr, resp = resp, gravity = gravity)
        // Sessions attributed to `day` = those whose end falls on `day` (UTC).
        val matched = allSessions.filter { dayString(it.end) == day }

        // ── Daily sleep aggregates (AASM, in-bed weighted) ────────────────────
        var deepS = 0.0
        var remS = 0.0
        var lightS = 0.0
        var tstS = 0.0
        var inBedS = 0.0
        var effWeighted = 0.0
        var disturbances = 0
        for (s in matched) {
            val m = SleepStager.hypnogramMetrics(s)
            val inBed = (s.end - s.start).toDouble()
            inBedS += inBed
            effWeighted += s.efficiency * inBed
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        val efficiency = if (inBedS > 0) effWeighted / inBedS else 0.0

        // Daily resting HR = lowest per-session resting HR across matched sessions.
        val restingHRDaily: Int? = matched.mapNotNull { it.restingHR }.minOrNull()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        val avgHRVDaily: Double? = run {
            val pairs = matched.mapNotNull { s ->
                s.avgHRV?.let { it to (s.end - s.start).toDouble() }
            }
            if (pairs.isEmpty()) {
                null
            } else {
                val total = pairs.sumOf { it.first * it.second }
                val weight = pairs.sumOf { it.second }
                if (weight > 0) total / weight else null
            }
        }

        // sleepStart/sleepEnd available for callers wiring sleep_start/end columns.
        @Suppress("UNUSED_VARIABLE") val sleepStart = matched.minOfOrNull { it.start }
        @Suppress("UNUSED_VARIABLE") val sleepEnd = matched.maxOfOrNull { it.end }

        // ── Recovery ──────────────────────────────────────────────────────────
        var recovery: Double? = null
        val hrvVal = avgHRVDaily
        val rhrVal = restingHRDaily
        val hrvBase = baselines.hrv
        if (hrvVal != null && rhrVal != null && hrvBase != null) {
            // Sleep-performance proxy = in-bed-weighted efficiency (0..1).
            val sleepPerf = if (matched.isEmpty()) null else efficiency
            recovery = RecoveryScorer.recovery(
                hrv = hrvVal,
                rhr = rhrVal.toDouble(),
                resp = null, // raw resp not aggregated to a nightly scalar here
                hrvBaseline = hrvBase,
                rhrBaseline = baselines.restingHR,
                respBaseline = baselines.resp,
                sleepPerf = sleepPerf,
            )
        }

        // ── Strain (day cardiovascular load over the full HR window) ──────────
        val effMaxHR: Double? = maxHROverride
            ?: if (profile.age > 0) StrainScorer.tanakaHRmax(profile.age) else null
        val restForStrain = restingHRDaily?.toDouble() ?: StrainScorer.defaultRestingHR
        val strain = StrainScorer.strain(
            hr = hr,
            maxHR = effMaxHR,
            restingHR = restForStrain,
            sex = profile.sex,
        )

        // ── Workouts ──────────────────────────────────────────────────────────
        val workouts = WorkoutDetector.detect(
            hr = hr,
            gravity = gravity,
            restingHR = restingHRDaily?.toDouble(),
            maxHR = maxHROverride,
            age = if (profile.age > 0) profile.age else null,
            profile = profile,
        )

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        // deviceId is stamped by the caller (IntelligenceEngine persists under
        // "<deviceId>-warbfit"); use the imported source id as a placeholder here so
        // the value type is complete. The caller copies with its computed id.
        val daily = DailyMetric(
            deviceId = "",
            day = day,
            totalSleepMin = if (matched.isEmpty()) null else tstS / 60.0,
            efficiency = if (matched.isEmpty()) null else efficiency,
            deepMin = if (matched.isEmpty()) null else deepS / 60.0,
            remMin = if (matched.isEmpty()) null else remS / 60.0,
            lightMin = if (matched.isEmpty()) null else lightS / 60.0,
            disturbances = if (matched.isEmpty()) null else disturbances,
            restingHr = restingHRDaily,
            avgHrv = avgHRVDaily,
            recovery = recovery,
            strain = strain,
            exerciseCount = workouts.size,
            spo2Pct = null,
            skinTempDevC = null,
            respRateBpm = null,
        )

        return DayResult(
            daily = daily,
            sleepSessions = matched,
            workouts = workouts,
            recovery = recovery,
            strain = strain,
        )
    }
}
