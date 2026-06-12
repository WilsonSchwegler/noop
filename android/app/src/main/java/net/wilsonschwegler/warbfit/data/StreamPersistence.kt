package net.wilsonschwegler.warbfit.data

import net.wilsonschwegler.warbfit.protocol.Streams
import org.json.JSONObject

/**
 * Bridge between the protocol-layer decode (`net.wilsonschwegler.warbfit.protocol.Streams`) and the Room data layer's
 * insert shape ([StreamBatch]).
 *
 * The live persistence path decodes frames with `extractStreams(...)` (which yields a protocol
 * `Streams` of hr/rr/events/battery) and then needs a [StreamBatch] to hand to
 * [TrackerRepository.insert]. This mapper performs that conversion, including the deterministic
 * sorted-keys JSON encoding of each event's residual payload — the exact analog of Swift
 * `TrackerStore.encodePayload(_:)` (JSONEncoder with `.sortedKeys`), so the same payload always
 * serializes byte-identically (important for the event natural-key dedupe + macOS parity).
 *
 * `ts` widens Int (protocol, wall-clock unix seconds) -> Long (Room), matching every other ts in
 * the store.
 */
object StreamPersistence {

    /** Convert a decoded protocol [Streams] batch into the Room [StreamBatch] insert shape. */
    fun toBatch(streams: Streams): StreamBatch = StreamBatch(
        hr = streams.hr.map { HrRow(it.ts.toLong(), it.bpm) },
        rr = streams.rr.map { RrRow(it.ts.toLong(), it.rrMs) },
        events = streams.events.map { EventEntry(it.ts.toLong(), it.kind, encodePayload(it.payload)) },
        battery = streams.battery.map { BatteryRow(it.ts.toLong(), it.soc, it.mv, it.charging) },
        // The live REALTIME_DATA stream carries no SpO2/skinTemp/resp/gravity — those are
        // type-47-only and arrive via the historical-offload path (extractHistoricalStreams).
    )

    /**
     * Deterministic sorted-keys JSON for an event payload. Port of `TrackerStore.encodePayload`.
     *
     * `org.json.JSONObject` does NOT guarantee key order, so we build the JSON manually with keys
     * sorted ascending (the same ordering `JSONEncoder.outputFormatting = [.sortedKeys]` produces),
     * quoting each value by its Kotlin type. Empty payloads encode to `{}`, matching Swift.
     *
     * Public so the historical-offload extractor (`net.wilsonschwegler.warbfit.protocol.extractHistoricalStreams`) can
     * encode offloaded EVENT payloads through the SAME canonical encoder the live path uses.
     */
    fun encodePayload(payload: Map<String, Any?>): String {
        if (payload.isEmpty()) return "{}"
        val sb = StringBuilder("{")
        val keys = payload.keys.sorted()
        for ((i, k) in keys.withIndex()) {
            if (i > 0) sb.append(',')
            sb.append(JSONObject.quote(k)).append(':').append(encodeValue(payload[k]))
        }
        sb.append('}')
        return sb.toString()
    }

    /** Encode one JSON value by Kotlin type (numbers bare, strings/bools/null literal, lists as arrays). */
    private fun encodeValue(v: Any?): String = when (v) {
        null -> "null"
        is Boolean -> v.toString()
        is Int, is Long -> v.toString()
        is Double, is Float -> {
            val d = (v as Number).toDouble()
            // Integral doubles render without a fractional suffix would diverge from Swift, but the
            // event residual payloads here are ints/strings/lists; keep doubles JSON-canonical.
            if (d.isFinite()) d.toString() else "null"
        }
        is List<*> -> buildString {
            append('[')
            for ((i, e) in v.withIndex()) {
                if (i > 0) append(',')
                append(encodeValue(e))
            }
            append(']')
        }
        is String -> JSONObject.quote(v)
        else -> JSONObject.quote(v.toString())
    }
}
