package net.wilsonschwegler.warbfit.ingest

import android.content.Context
import android.net.Uri
import android.util.Xml
import net.wilsonschwegler.warbfit.data.AppleDaily
import net.wilsonschwegler.warbfit.data.DailyMetric
import net.wilsonschwegler.warbfit.data.ImportSummary
import net.wilsonschwegler.warbfit.data.MetricSeriesRow
import net.wilsonschwegler.warbfit.data.TrackerRepository
import net.wilsonschwegler.warbfit.data.WorkoutRow
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedInputStream
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Apple Health export importer.
 *
 * Reproduces FAITHFULLY:
 *  - the relevant `HKQuantityTypeIdentifier` / `HKCategoryTypeIdentifier` set and prefix stripping,
 *  - the `<Correlation>`-nested `<Record>` skip + `type|start|end|source|value` dedupe,
 *  - `OxygenSaturation` 0..1 fraction -> percent,
 *  - the `SleepAnalysis` category-value -> stage mapping,
 *  - per-day reduction rules (means for HR/HRV/SpO2/resp/walking/resting/avgHr, max for maxHr,
 *    sums for steps/active/basal, latest-by-end for VO2Max / BodyMass),
 *  - sample bucketing on the LOCAL day of `start`, sleep bucketing on the LOCAL day of `end`
 *    (the wake day), with `asleep = core + deep + rem + asleepUnspecified`.
 *
 * Streams with `Xml.newPullParser()` over the raw `InputStream` — never a DOM, never the whole
 * (multi-hundred-MB / multi-GB) file in memory. Aggregation is bucketed per day; per-day
 * accumulators hold running sums/counts (not raw sample arrays) so peak memory stays bounded by
 * the number of distinct days, not the number of records.
 *
 * Maps the macOS `AppleDailyAggregate` onto the Android Room schema (package `net.wilsonschwegler.warbfit.data`):
 *  - AppleDaily(deviceId="apple-health"): steps, activeKcal, basalKcal, vo2max, avgHr, maxHr,
 *    walkingHr, weightKg
 *  - DailyMetric(deviceId="apple-health"): restingHr, avgHrv, totalSleepMin, deepMin, remMin,
 *    lightMin (= sleep core), spo2Pct, respRateBpm
 *  - WorkoutRow(source="apple-health"): one per `<Workout>` element
 *  - MetricSeriesRow(deviceId="apple-health"): the flattened (day, key, value) metric points
 *
 * Body-composition extras the macOS aggregator also computes (bodyFatPct, leanMassKg, bmi) have
 * no column in the Android schema and are intentionally dropped (only `weightKg` survives, in
 * AppleDaily). See `risks` in the task summary.
 */
object AppleHealthImporter {

    const val SOURCE_LABEL = "Apple Health"
    const val DEFAULT_DEVICE_ID = "apple-health"

    /** Health types Strand cares about (HK prefix already stripped). Mirrors `relevantTypes`. */
    private val RELEVANT_TYPES: Set<String> = setOf(
        "HeartRate",
        "RestingHeartRate",
        "HeartRateVariabilitySDNN",
        "WalkingHeartRateAverage",
        "OxygenSaturation",
        "BodyTemperature",
        "AppleSleepingWristTemperature",
        "RespiratoryRate",
        "ActiveEnergyBurned",
        "BasalEnergyBurned",
        "VO2Max",
        "StepCount",
        "SleepAnalysis",
        // Body composition
        "BodyMass",
        "BodyFatPercentage",
        "LeanBodyMass",
        "BodyMassIndex",
    )

    // ------------------------------------------------------------------------
    // Public entry point
    // ------------------------------------------------------------------------

    /**
     * Import an Apple Health export from a SAF [uri]. The uri may point at:
     *  - an `export.zip` (Apple nests the XML under `apple_health_export/export.xml`), or
     *  - a raw `export.xml`.
     *
     * The content is read via `context.contentResolver.openInputStream(uri)` and stream-parsed.
     * Aggregated rows are upserted into [repo] under [deviceId] (DailyMetric / AppleDaily /
     * MetricSeriesRow) and "apple-health" as `source` (WorkoutRow). Returns an [ImportSummary]
     * keyed by table name; on any failure returns [ImportSummary.failure].
     */
    suspend fun importExport(
        context: Context,
        uri: Uri,
        repo: TrackerRepository,
        deviceId: String = DEFAULT_DEVICE_ID,
    ): ImportSummary {
        val agg = Aggregator()
        try {
            context.contentResolver.openInputStream(uri)?.use { raw ->
                val buffered = BufferedInputStream(raw, 1 shl 16)
                if (isZip(buffered)) {
                    parseZip(buffered, agg)
                } else {
                    parseXml(buffered, agg)
                }
            } ?: return ImportSummary.failure(SOURCE_LABEL, "Could not open the selected file.")
        } catch (e: MissingExportXml) {
            return ImportSummary.failure(SOURCE_LABEL, "No export.xml found inside the archive.")
        } catch (e: Exception) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "Could not read the Apple Health export: ${e.message ?: e.javaClass.simpleName}",
            )
        }

        return persist(agg, repo, deviceId)
    }

    // ------------------------------------------------------------------------
    // Zip handling — locate export.xml anywhere in the archive and stream it.
    // ------------------------------------------------------------------------

    private class MissingExportXml : Exception()

    /** Peek the first 4 bytes for the local-file-header magic `PK`. */
    private fun isZip(input: BufferedInputStream): Boolean {
        input.mark(4)
        val sig = ByteArray(4)
        val n = input.read(sig, 0, 4)
        input.reset()
        if (n < 4) return false
        return sig[0] == 'P'.code.toByte() &&
            sig[1] == 'K'.code.toByte() &&
            sig[2].toInt() == 0x03 &&
            sig[3].toInt() == 0x04
    }

    /**
     * Stream the zip with [ZipInputStream], find the first entry whose basename is `export.xml`
     * (case-insensitive — Apple nests it under `apple_health_export/`), and stream-parse it WITHOUT
     * inflating to disk or RAM first. The entry stream is parsed directly off the inflating stream;
     * a guarded wrapper prevents the pull-parser from closing the underlying zip stream.
     */
    private fun parseZip(input: InputStream, agg: Aggregator) {
        val zip = ZipInputStream(input)
        var entry = zip.nextEntry
        while (entry != null) {
            if (!entry.isDirectory && baseName(entry.name).equals("export.xml", ignoreCase = true)) {
                parseXml(NonClosingInputStream(zip), agg)
                return
            }
            zip.closeEntry()
            entry = zip.nextEntry
        }
        throw MissingExportXml()
    }

    private fun baseName(path: String): String {
        val p = path.replace('\\', '/')
        val idx = p.lastIndexOf('/')
        return if (idx >= 0) p.substring(idx + 1) else p
    }

    /** Prevents the XML pull-parser from closing the shared underlying stream (the zip). */
    private class NonClosingInputStream(private val delegate: InputStream) : InputStream() {
        override fun read(): Int = delegate.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = delegate.read(b, off, len)
        override fun available(): Int = delegate.available()
        override fun close() { /* no-op: keep the zip stream open */ }
    }

    // ------------------------------------------------------------------------
    // Streaming XML parse (Xml.newPullParser / XmlPullParser).
    // ------------------------------------------------------------------------

    /**
     * Pull-parse the export, tracking `<Correlation>` nesting so `<Record>`s inside a correlation
     * are skipped (they also appear top-level). Dispatches each top-level `<Record>` and every
     * `<Workout>` straight into the [Aggregator], which buckets by day immediately — no per-record
     * objects are retained.
     */
    private fun parseXml(input: InputStream, agg: Aggregator) {
        val parser: XmlPullParser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(input, null) // null encoding => parser reads the XML declaration

        var correlationDepth = 0
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "Correlation" -> correlationDepth += 1
                    "Record" -> if (correlationDepth == 0) handleRecord(parser, agg)
                    "Workout" -> handleWorkout(parser, agg)
                    else -> { /* ignore */ }
                }
                XmlPullParser.END_TAG -> if (parser.name == "Correlation" && correlationDepth > 0) {
                    correlationDepth -= 1
                }
            }
            event = parser.next()
        }
    }

    private fun attr(parser: XmlPullParser, name: String): String? = parser.getAttributeValue(null, name)

    // MARK: Record handling — mirrors HealthXMLDelegate.handleRecord + Aggregator rules.

    private fun handleRecord(parser: XmlPullParser, agg: Aggregator) {
        val rawType = attr(parser, "type") ?: return
        val type = stripPrefix(rawType)
        if (type !in RELEVANT_TYPES) return

        val startStr = attr(parser, "startDate") ?: return
        val endStr = attr(parser, "endDate") ?: return
        val start = HealthDate.parse(startStr) ?: return
        val end = HealthDate.parse(endStr) ?: return

        val source = attr(parser, "sourceName")
        val unit = attr(parser, "unit")
        val rawValue = attr(parser, "value")

        if (type == "SleepAnalysis") {
            val stage = SleepStage.from(rawValue ?: "")
            // Faithful to the macOS importer: sleep-stage intervals are appended UNCONDITIONALLY
            // (the dedupe set there only protects the generic *sample* sink, not `sleepIntervals`).
            // Top-level records are already de-correlated, so duplicates are not expected in
            // practice, but we match the Swift behaviour exactly rather than dedupe here.
            agg.addSleep(stage, start, end, end.offsetMin)
            return
        }

        val raw = rawValue?.toDoubleOrNull()
        var numeric = raw
        if (type == "OxygenSaturation" && numeric != null) {
            numeric = numeric * 100.0
        }

        val valueForKey = rawValue ?: numeric?.toString() ?: ""
        val key = dedupeKey(type, start.epoch, end.epoch, source, valueForKey)
        if (!agg.markSeen(key)) return

        if (numeric == null) return
        agg.addSample(type, numeric, unit, start, end, start.offsetMin)
    }

    // MARK: Workout handling — mirrors HealthXMLDelegate.handleWorkout.

    private fun handleWorkout(parser: XmlPullParser, agg: Aggregator) {
        val startStr = attr(parser, "startDate") ?: return
        val endStr = attr(parser, "endDate") ?: return
        val start = HealthDate.parse(startStr) ?: return
        val end = HealthDate.parse(endStr) ?: return

        val rawActivity = attr(parser, "workoutActivityType") ?: "Unknown"
        val activity = stripPrefix(rawActivity)

        var durationS: Double? = null
        val dStr = attr(parser, "duration")
        if (dStr != null) {
            val d = dStr.toDoubleOrNull()
            if (d != null) {
                durationS = when ((attr(parser, "durationUnit") ?: "min").lowercase()) {
                    "min" -> d * 60.0
                    "sec", "s" -> d
                    "hr", "h" -> d * 3600.0
                    else -> d * 60.0
                }
            }
        }

        var distanceM: Double? = null
        val distStr = attr(parser, "totalDistance")
        if (distStr != null) {
            val dist = distStr.toDoubleOrNull()
            if (dist != null) {
                distanceM = when ((attr(parser, "totalDistanceUnit") ?: "km").lowercase()) {
                    "km" -> dist * 1000.0
                    "mi" -> dist * 1609.344
                    "m" -> dist
                    else -> dist * 1000.0
                }
            }
        }

        val energyKcal = attr(parser, "totalEnergyBurned")?.toDoubleOrNull()

        agg.addWorkout(activity, durationS, distanceM, energyKcal, start, end)
    }

    // ------------------------------------------------------------------------
    // Persistence — map aggregates onto the Room schema and upsert.
    // ------------------------------------------------------------------------

    private suspend fun persist(
        agg: Aggregator,
        repo: TrackerRepository,
        deviceId: String,
    ): ImportSummary {
        val days = agg.finishDays() // sorted ascending by day; union of sample + sleep days

        if (days.isEmpty()) {
            return ImportSummary(
                source = SOURCE_LABEL,
                counts = emptyMap(),
                message = "No supported Apple Health data found in the export.",
            )
        }

        repo.upsertDevice(deviceId, name = SOURCE_LABEL)

        val appleDailyRows = ArrayList<AppleDaily>(days.size)
        val dailyMetricRows = ArrayList<DailyMetric>(days.size)
        val metricSeriesRows = ArrayList<MetricSeriesRow>(days.size * 8)

        for (d in days) {
            appleDailyRows += AppleDaily(
                deviceId = deviceId,
                day = d.day,
                steps = d.steps?.let { Math.round(it).toInt() },
                activeKcal = d.activeKcal,
                basalKcal = d.basalKcal,
                vo2max = d.vo2max,
                avgHr = d.avgHr?.let { Math.round(it).toInt() },
                maxHr = d.maxHr?.let { Math.round(it).toInt() },
                walkingHr = d.walkingHr?.let { Math.round(it).toInt() },
                weightKg = d.weightKg,
            )

            // DailyMetric carries the cardio/respiratory/sleep aggregates Apple Health provides.
            // Other DailyMetric columns (efficiency, recovery, strain, disturbances, exerciseCount,
            // skinTempDevC) are not derivable from an Apple Health export and stay null.
            val hasDailyMetric = d.restingHr != null || d.hrvSDNN != null || d.spo2Pct != null ||
                d.respRate != null || d.asleepMin != null || d.deepMin != null || d.remMin != null ||
                d.coreMin != null
            if (hasDailyMetric) {
                dailyMetricRows += DailyMetric(
                    deviceId = deviceId,
                    day = d.day,
                    totalSleepMin = d.asleepMin,
                    deepMin = d.deepMin,
                    remMin = d.remMin,
                    lightMin = d.coreMin, // Apple "core" sleep is the light-sleep stage
                    restingHr = d.restingHr?.let { Math.round(it).toInt() },
                    avgHrv = d.hrvSDNN,
                    spo2Pct = d.spo2Pct,
                    respRateBpm = d.respRate,
                )
            }

            // Flattened metric points — mirrors AppleHealthAggregator.metricPoints key set.
            fun add(key: String, value: Double?) {
                if (value != null) metricSeriesRows += MetricSeriesRow(deviceId, d.day, key, value)
            }
            add("resting_hr", d.restingHr)
            add("hrv", d.hrvSDNN)
            add("spo2", d.spo2Pct)
            add("resp_rate", d.respRate)
            add("avg_hr", d.avgHr)
            add("max_hr", d.maxHr)
            add("walking_hr", d.walkingHr)
            add("steps", d.steps)
            add("active_kcal", d.activeKcal)
            add("basal_kcal", d.basalKcal)
            add("vo2max", d.vo2max)
            add("weight", d.weightKg)
            add("body_fat", d.bodyFatPct)
            add("lean_mass", d.leanMassKg)
            add("bmi", d.bmi)
            add("asleep_min", d.asleepMin)
            add("deep_min", d.deepMin)
            add("rem_min", d.remMin)
            add("core_min", d.coreMin)
            add("awake_min", d.awakeMin)
            add("in_bed_min", d.inBedMin)
        }

        val workoutRows = agg.finishWorkouts(deviceId)

        // Upsert (Room OnConflictStrategy on each repo method handles idempotent re-import).
        repo.upsertAppleDaily(appleDailyRows)
        if (dailyMetricRows.isNotEmpty()) repo.upsertDailyMetrics(dailyMetricRows)
        if (metricSeriesRows.isNotEmpty()) repo.upsertMetricSeries(metricSeriesRows)
        if (workoutRows.isNotEmpty()) repo.upsertWorkouts(workoutRows)

        val counts = LinkedHashMap<String, Int>()
        counts["appleDaily"] = appleDailyRows.size
        if (dailyMetricRows.isNotEmpty()) counts["dailyMetric"] = dailyMetricRows.size
        if (metricSeriesRows.isNotEmpty()) counts["metricSeries"] = metricSeriesRows.size
        if (workoutRows.isNotEmpty()) counts["workout"] = workoutRows.size

        val firstDay = days.first().day
        val lastDay = days.last().day
        val message = buildString {
            append("Imported ")
            append(appleDailyRows.size)
            append(" day")
            if (appleDailyRows.size != 1) append("s")
            if (workoutRows.isNotEmpty()) {
                append(", ")
                append(workoutRows.size)
                append(" workout")
                if (workoutRows.size != 1) append("s")
            }
            append(" from Apple Health.")
        }

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = message,
        )
    }

    // ------------------------------------------------------------------------
    // Helpers — prefix stripping, dedupe key, sleep-stage mapping.
    // ------------------------------------------------------------------------

    /**
     * Strip the HealthKit identifier prefix. `HKQuantityTypeIdentifierHeartRate` -> `HeartRate`,
     * `HKCategoryTypeIdentifierSleepAnalysis` -> `SleepAnalysis`,
     * `HKWorkoutActivityTypeRunning` -> `Running`. Mirrors `AppleHealthImporter.stripPrefix`.
     */
    private val PREFIXES = arrayOf(
        "HKQuantityTypeIdentifier",
        "HKCategoryTypeIdentifier",
        "HKDataTypeIdentifier",
        "HKWorkoutActivityType",
    )

    private fun stripPrefix(raw: String): String {
        for (p in PREFIXES) if (raw.startsWith(p)) return raw.substring(p.length)
        return raw
    }

    /** Dedupe key per spec: `type|start|end|source|value` (epoch seconds as Double, like Swift). */
    private fun dedupeKey(type: String, start: Double, end: Double, source: String?, value: String): String =
        "$type|$start|$end|${source ?: ""}|$value"
}

/**
 * Canonical sleep stages Strand recognises from Apple Health `HKCategoryValueSleepAnalysis*`
 * values. Mirrors `SleepStage` + `SleepStage.from(rawValue:)` in `ImportModels.swift`.
 */
private enum class SleepStage {
    IN_BED, ASLEEP_UNSPECIFIED, ASLEEP_CORE, ASLEEP_DEEP, ASLEEP_REM, AWAKE, UNKNOWN;

    companion object {
        fun from(raw: String): SleepStage = when (raw) {
            "HKCategoryValueSleepAnalysisInBed", "InBed", "0" -> IN_BED
            "HKCategoryValueSleepAnalysisAsleep",
            "HKCategoryValueSleepAnalysisAsleepUnspecified", "Asleep", "1" -> ASLEEP_UNSPECIFIED
            "HKCategoryValueSleepAnalysisAsleepCore", "AsleepCore", "3" -> ASLEEP_CORE
            "HKCategoryValueSleepAnalysisAsleepDeep", "AsleepDeep", "4" -> ASLEEP_DEEP
            "HKCategoryValueSleepAnalysisAsleepREM", "AsleepREM", "5" -> ASLEEP_REM
            "HKCategoryValueSleepAnalysisAwake", "Awake", "2" -> AWAKE
            else -> UNKNOWN
        }
    }
}

/**
 * A parsed Apple Health timestamp: the UTC instant in epoch SECONDS plus the original UTC offset
 * (minutes). Apple exports `yyyy-MM-dd HH:mm:ss Z` (space before a colon-less offset). We parse the
 * fields directly rather than via SimpleDateFormat to avoid per-record allocation across tens of
 * millions of records, and compute the epoch with a pure-arithmetic civil-day algorithm.
 */
private class HealthDate(val epoch: Double, val offsetMin: Int) {

    companion object {
        /**
         * Parse `yyyy-MM-dd HH:mm:ss ±HHMM` / `±HH:MM` / `Z`. Also tolerates an ISO-8601 `T`
         * separator. Returns null on anything unparseable (matching the Swift importer's silent skip).
         */
        fun parse(raw: String): HealthDate? {
            val s = raw.trim()
            if (s.length < 19) return null

            // Date: yyyy-MM-dd
            val year = intAt(s, 0, 4) ?: return null
            if (s[4] != '-') return null
            val month = intAt(s, 5, 2) ?: return null
            if (s[7] != '-') return null
            val day = intAt(s, 8, 2) ?: return null

            val sep = s[10]
            if (sep != ' ' && sep != 'T' && sep != 't') return null

            // Time: HH:mm:ss
            val hour = intAt(s, 11, 2) ?: return null
            if (s[13] != ':') return null
            val minute = intAt(s, 14, 2) ?: return null
            if (s[16] != ':') return null
            val second = intAt(s, 17, 2) ?: return null

            val offsetMin = offsetMinutes(s)

            // Days since Unix epoch (1970-01-01) for this civil Y-M-D, then add the time-of-day, then
            // subtract the offset to get the true UTC instant. (epoch_local - offset = epoch_utc)
            val days = daysFromCivil(year, month, day)
            val localSecs = days * 86400.0 + hour * 3600.0 + minute * 60.0 + second
            val utcSecs = localSecs - offsetMin * 60.0
            return HealthDate(utcSecs, offsetMin)
        }

        private fun intAt(s: String, start: Int, len: Int): Int? {
            if (start + len > s.length) return null
            var acc = 0
            for (i in start until start + len) {
                val c = s[i]
                if (c < '0' || c > '9') return null
                acc = acc * 10 + (c - '0')
            }
            return acc
        }

        /**
         * Days from 1970-01-01 to the given proleptic-Gregorian civil date (may be negative).
         * Howard Hinnant's `days_from_civil` algorithm — exact, no DST, no allocation.
         */
        private fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
            val y = if (m <= 2) y0 - 1 else y0
            val era = (if (y >= 0) y else y - 399) / 400
            val yoe = (y - era * 400).toLong()                       // [0, 399]
            val doy = ((153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1).toLong() // [0, 365]
            val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy          // [0, 146096]
            return era.toLong() * 146097L + doe - 719468L
        }

        /**
         * Extract the trailing UTC offset (`+0100`, `-0500`, `+01:00`, `Z`) in minutes. Mirrors
         * `HealthDateParser.offsetMinutes`.
         */
        fun offsetMinutes(raw: String): Int {
            val trimmed = raw.trim()
            if (trimmed.endsWith("Z") || trimmed.endsWith("z")) return 0
            // The offset is the last token; look within the last ~6 chars for a sign.
            val tail = trimmed.takeLast(6)
            var signIdx = -1
            for (i in tail.indices) if (tail[i] == '+' || tail[i] == '-') { signIdx = i; break }
            if (signIdx < 0) return 0
            val offStr = tail.substring(signIdx)
            val sign = if (offStr.startsWith("-")) -1 else 1
            val digits = StringBuilder()
            for (c in offStr.drop(1)) if (c.isDigit()) digits.append(c)
            if (digits.length < 2) return 0
            val ds = digits.toString()
            val hours: Int
            val minutes: Int
            if (ds.length >= 4) {
                hours = ds.substring(0, 2).toIntOrNull() ?: 0
                minutes = ds.substring(2, 4).toIntOrNull() ?: 0
            } else {
                hours = ds.substring(0, 2).toIntOrNull() ?: 0
                minutes = 0
            }
            return sign * (hours * 60 + minutes)
        }
    }
}

/**
 * Bounded, streaming per-day aggregator. Holds running statistics (sums + counts for means,
 * running max, latest-by-end value) per distinct day — NOT raw sample lists — so memory scales
 * with the number of days, not the number of records.
 *
 * Reproduces the reduction rules from `AppleHealthAggregator`:
 *  - mean: restingHr, hrvSDNN, spo2, respRate, walkingHr, avgHr
 *  - max: maxHr
 *  - sum: steps, activeEnergy, basalEnergy
 *  - latest by sample `end`: vo2max, bodyMass(weightKg), bodyFat, leanMass, bmi
 *  - sample day = local day of `start`; sleep day = local day of `end` (wake day)
 *  - asleep = core + deep + rem + asleepUnspecified
 */
private class Aggregator {

    /** Running mean: sum + count. */
    private class Mean {
        var sum = 0.0
        var n = 0
        fun add(v: Double) { sum += v; n += 1 }
        fun value(): Double? = if (n == 0) null else sum / n
    }

    /** Latest-by-end value. */
    private class Latest {
        var value: Double? = null
        var at = Double.NEGATIVE_INFINITY // sample end epoch
        fun consider(v: Double, end: Double) {
            if (value == null || at <= end) { value = v; at = end }
        }
    }

    private class DayAcc {
        val resting = Mean()
        val hrv = Mean()
        val spo2 = Mean()
        val resp = Mean()
        val walking = Mean()
        val hr = Mean()
        var maxHr = Double.NEGATIVE_INFINITY
        var hasHr = false
        var steps = 0.0; var hasSteps = false
        var active = 0.0; var hasActive = false
        var basal = 0.0; var hasBasal = false
        val vo2 = Latest()
        val weight = Latest()
        val bodyFat = Latest()
        val lean = Latest()
        val bmi = Latest()
        // Sleep minutes per stage (keyed by wake day).
        var deep = 0.0
        var rem = 0.0
        var core = 0.0
        var unspecified = 0.0
        var awake = 0.0
        var inBed = 0.0
        var hasSleep = false
    }

    private val byDay = HashMap<String, DayAcc>()
    private val seen = HashSet<String>()
    private val workouts = ArrayList<PendingWorkout>()

    private class PendingWorkout(
        val sport: String,
        val startTs: Long,
        val endTs: Long,
        val durationS: Double?,
        val distanceM: Double?,
        val energyKcal: Double?,
    )

    /** Returns true if [key] was not seen before (i.e. this row should be processed). */
    fun markSeen(key: String): Boolean = seen.add(key)

    private fun acc(day: String): DayAcc = byDay.getOrPut(day) { DayAcc() }

    private fun localDay(epochSecs: Double, offsetMin: Int): String {
        val shifted = epochSecs + offsetMin * 60.0
        val days = Math.floorDiv(shifted.toLong(), 86400L)
        return civilFromDays(days)
    }

    fun addSample(type: String, value: Double, unit: String?, start: HealthDate, end: HealthDate, offsetMin: Int) {
        val day = localDay(start.epoch, offsetMin)
        val a = acc(day)
        when (type) {
            "RestingHeartRate" -> a.resting.add(value)
            "HeartRateVariabilitySDNN" -> a.hrv.add(value)
            "OxygenSaturation" -> {
                // Importer already scaled by 100; defend against raw 0..1 fractions too.
                val pct = if (value > 0 && value <= 1.0) value * 100.0 else value
                a.spo2.add(pct)
            }
            "RespiratoryRate" -> a.resp.add(value)
            "WalkingHeartRateAverage" -> a.walking.add(value)
            "HeartRate" -> {
                a.hr.add(value)
                if (!a.hasHr || value > a.maxHr) { a.maxHr = value; a.hasHr = true }
            }
            "StepCount" -> { a.steps += value; a.hasSteps = true }
            "ActiveEnergyBurned" -> { a.active += value; a.hasActive = true }
            "BasalEnergyBurned" -> { a.basal += value; a.hasBasal = true }
            "VO2Max" -> a.vo2.consider(value, end.epoch)
            "BodyMass" -> a.weight.consider(if (unitLooksLikePounds(unit)) value * 0.453592 else value, end.epoch)
            "BodyFatPercentage" -> {
                val pct = if (value > 0 && value <= 1.0) value * 100.0 else value
                a.bodyFat.consider(pct, end.epoch)
            }
            "LeanBodyMass" -> a.lean.consider(if (unitLooksLikePounds(unit)) value * 0.453592 else value, end.epoch)
            "BodyMassIndex" -> a.bmi.consider(value, end.epoch)
            // BodyTemperature / AppleSleepingWristTemperature pass the relevant-type filter but
            // have no daily aggregate slot in the macOS aggregator either — intentionally dropped.
            else -> { /* ignore */ }
        }
    }

    fun addSleep(stage: SleepStage, start: HealthDate, end: HealthDate, offsetMin: Int) {
        val minutes = Math.max(0.0, (end.epoch - start.epoch)) / 60.0
        val day = localDay(end.epoch, offsetMin) // wake day = local day of end
        val a = acc(day)
        when (stage) {
            SleepStage.ASLEEP_DEEP -> a.deep += minutes
            SleepStage.ASLEEP_REM -> a.rem += minutes
            SleepStage.ASLEEP_CORE -> a.core += minutes
            SleepStage.ASLEEP_UNSPECIFIED -> a.unspecified += minutes
            SleepStage.AWAKE -> a.awake += minutes
            SleepStage.IN_BED -> a.inBed += minutes
            SleepStage.UNKNOWN -> { /* ignore */ }
        }
        a.hasSleep = true
    }

    fun addWorkout(sport: String, durationS: Double?, distanceM: Double?, energyKcal: Double?, start: HealthDate, end: HealthDate) {
        workouts += PendingWorkout(
            sport = sport,
            startTs = Math.round(start.epoch),
            endTs = Math.round(end.epoch),
            durationS = durationS,
            distanceM = distanceM,
            energyKcal = energyKcal,
        )
    }

    /** Finalize per-day aggregates, sorted ascending by day. */
    fun finishDays(): List<DailyAgg> = byDay.entries
        .map { (day, a) ->
            DailyAgg(
                day = day,
                restingHr = a.resting.value(),
                hrvSDNN = a.hrv.value(),
                spo2Pct = a.spo2.value(),
                respRate = a.resp.value(),
                avgHr = a.hr.value(),
                maxHr = if (a.hasHr) a.maxHr else null,
                walkingHr = a.walking.value(),
                steps = if (a.hasSteps) a.steps else null,
                activeKcal = if (a.hasActive) a.active else null,
                basalKcal = if (a.hasBasal) a.basal else null,
                vo2max = a.vo2.value,
                weightKg = a.weight.value,
                bodyFatPct = a.bodyFat.value,
                leanMassKg = a.lean.value,
                bmi = a.bmi.value,
                asleepMin = if (a.hasSleep) a.core + a.deep + a.rem + a.unspecified else null,
                deepMin = if (a.hasSleep) a.deep else null,
                remMin = if (a.hasSleep) a.rem else null,
                coreMin = if (a.hasSleep) a.core else null,
                awakeMin = if (a.hasSleep) a.awake else null,
                inBedMin = if (a.hasSleep) a.inBed else null,
            )
        }
        .sortedBy { it.day }

    /**
     * Finalize workout rows. The Room `workout` table PK is (deviceId, startTs, sport), so any
     * Apple Health workouts colliding on that key collapse via the upsert (matching how the macOS
     * cache keys workouts). `durationS` falls back to (endTs - startTs) when absent.
     */
    fun finishWorkouts(deviceId: String): List<WorkoutRow> = workouts.map { w ->
        WorkoutRow(
            deviceId = deviceId,
            startTs = w.startTs,
            endTs = w.endTs,
            sport = w.sport,
            source = "apple-health",
            durationS = w.durationS ?: (w.endTs - w.startTs).toDouble(),
            energyKcal = w.energyKcal,
            avgHr = null,
            maxHr = null,
            strain = null,
            distanceM = w.distanceM,
            zonesJSON = null,
            notes = null,
        )
    }

    private fun unitLooksLikePounds(unit: String?): Boolean {
        val u = unit?.lowercase() ?: return false
        return u == "lb" || u == "lbs" || u.contains("pound")
    }

    companion object {
        /** Inverse of HealthDate.daysFromCivil — days since epoch -> `yyyy-MM-dd` (UTC civil). */
        fun civilFromDays(z0: Long): String {
            val z = z0 + 719468L
            val era = (if (z >= 0) z else z - 146096L) / 146097L
            val doe = z - era * 146097L                         // [0, 146096]
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
            val y = yoe + era * 400L
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)   // [0, 365]
            val mp = (5 * doy + 2) / 153                        // [0, 11]
            val d = (doy - (153 * mp + 2) / 5 + 1).toInt()      // [1, 31]
            val m = (if (mp < 10) mp + 3 else mp - 9).toInt()   // [1, 12]
            val year = (if (m <= 2) y + 1 else y).toInt()
            return String.format("%04d-%02d-%02d", year, m, d)
        }
    }
}

/** Finalized per-day aggregate mirroring `AppleDailyAggregate`. */
private class DailyAgg(
    val day: String,
    val restingHr: Double?,
    val hrvSDNN: Double?,
    val spo2Pct: Double?,
    val respRate: Double?,
    val avgHr: Double?,
    val maxHr: Double?,
    val walkingHr: Double?,
    val steps: Double?,
    val activeKcal: Double?,
    val basalKcal: Double?,
    val vo2max: Double?,
    val weightKg: Double?,
    val bodyFatPct: Double?,
    val leanMassKg: Double?,
    val bmi: Double?,
    val asleepMin: Double?,
    val deepMin: Double?,
    val remMin: Double?,
    val coreMin: Double?,
    val awakeMin: Double?,
    val inBedMin: Double?,
)
