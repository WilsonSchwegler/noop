package net.wilsonschwegler.warbfit.protocol

/**
 * Decoded stream rows — the durable, compact local record produced from parsed frames.
 *
 * Ported from the Swift reference (Streams.swift). `ts` is wall-clock unix seconds throughout.
 * These are pure data carriers with no Android/Room dependency; the data layer maps them onto
 * Room entities (HrSample, RrInterval, EventRow, BatterySample) as needed.
 */

/** A heart-rate sample at wall-clock unix seconds [ts]. */
data class HrSample(val ts: Int, val bpm: Int)

/** A single beat-to-beat R-R interval (ms) at wall-clock unix seconds [ts]. */
data class RrInterval(val ts: Int, val rrMs: Int)

/**
 * A device event. [ts] is real RTC unix seconds (already wall-clock, never offset). [kind] is the
 * event label (e.g. "BATTERY_LEVEL(3)", "WRIST_OFF(10)"); [payload] carries any extra decoded
 * fields with `event`/`event_timestamp` removed.
 */
data class WhoopEvent(val ts: Int, val kind: String, val payload: Map<String, Any?>)

/**
 * A battery reading. [ts] is event RTC for BATTERY_LEVEL events, else the wall-clock reference.
 * [charging] is a real Boolean only when the frame reported it (BATTERY_LEVEL events); `null`
 * otherwise (command responses).
 */
data class BatterySample(
    val ts: Int,
    val soc: Double?,
    val mv: Int?,
    val charging: Boolean? = null,
)

/** The bundle of decoded series extracted from a batch of parsed frames. */
data class Streams(
    val hr: MutableList<HrSample> = mutableListOf(),
    val rr: MutableList<RrInterval> = mutableListOf(),
    val events: MutableList<WhoopEvent> = mutableListOf(),
    val battery: MutableList<BatterySample> = mutableListOf(),
) {
    companion object {
        val EMPTY: Streams get() = Streams()
    }
}

/**
 * Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
 * Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of `_to_wall`.
 */
private fun toWall(deviceTs: Int?, deviceClockRef: Int, wallClockRef: Int): Int? {
    if (deviceTs == null) return null
    return wallClockRef + (deviceTs - deviceClockRef)
}

/**
 * Turn parsed frames into datastore rows. Port of `interpreter.extract_streams`.
 *
 * HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also carries an
 * HR byte but streams alongside type-40 during raw collection, so routing both would double-count
 * HR for the same instants. CRC-failed and non-ok frames are skipped.
 */
fun extractStreams(parsed: List<ParsedFrame>, deviceClockRef: Int, wallClockRef: Int): Streams {
    val out = Streams()
    for (r in parsed) {
        if (!r.ok || r.crcOk == false) continue
        val p = r.parsed
        when (r.typeName) {
            "REALTIME_DATA" -> {
                val ts = toWall(p.intOrNull("timestamp"), deviceClockRef, wallClockRef)
                if (ts != null) {
                    p.intOrNull("heart_rate")?.let { bpm -> out.hr.add(HrSample(ts, bpm)) }
                    // Drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
                    p.intArrayOrNull("rr_intervals")?.let { rrs ->
                        for (rr in rrs) out.rr.add(RrInterval(ts, rr))
                    }
                }
            }

            "EVENT" -> {
                // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
                val ts = p.intOrNull("event_timestamp") ?: continue
                val kind = p.stringOrNull("event") ?: ""
                // BATTERY_LEVEL events (~every 8 min) carry SoC/mV/charging → the DENSE series.
                if (kind.startsWith("BATTERY_LEVEL")) appendBattery(out, ts, p)
                val payload = p.toMutableMap()
                payload.remove("event")
                payload.remove("event_timestamp")
                out.events.add(WhoopEvent(ts, kind, payload))
            }

            "COMMAND_RESPONSE" -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
                appendBattery(out, wallClockRef, p)
            }

            else -> Unit
        }
    }
    return out
}

/**
 * Append a [BatterySample] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging`
 * fields (no-op when neither soc nor mv is present). `charging` is a real Boolean only when the
 * frame reported it (BATTERY_LEVEL events); command responses leave it null.
 */
internal fun appendBattery(out: Streams, ts: Int, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.battery.add(BatterySample(ts = ts, soc = soc, mv = mv, charging = charging))
}

// MARK: - Heterogeneous parsed-map accessors (mirror Swift's ParsedValue.intValue/etc.)

internal fun Map<String, Any?>.intOrNull(key: String): Int? = when (val v = this[key]) {
    is Int -> v
    is Long -> v.toInt()
    else -> null
}

internal fun Map<String, Any?>.doubleOrNull(key: String): Double? = when (val v = this[key]) {
    is Double -> v
    is Int -> v.toDouble()
    is Long -> v.toDouble()
    else -> null
}

internal fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.intArrayOrNull(key: String): List<Int>? = this[key] as? List<Int>
