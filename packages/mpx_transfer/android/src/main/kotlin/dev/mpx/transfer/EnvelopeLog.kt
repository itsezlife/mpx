package dev.mpx.transfer

import android.util.Log
import org.json.JSONObject

/**
 * Where the envelope's native diagnostics go. Every record is written to
 * logcat under [TAG]; it then crosses the channel to Dart when a Dart side
 * is attached ([sink]), or lands in the ring file ([ring]) to be merged at
 * the next start.
 *
 * A record carries no user content: ops, handles, job ids, counts and
 * causes only.
 */
/**
 * How much an envelope record matters: the Dart side's `MpxEventLevel`, by
 * its [wireName], and the logcat [priority] it is written at.
 */
enum class EnvelopeLevel(val wireName: String, val priority: Int) {
    TRACE("trace", Log.VERBOSE),
    DEBUG("debug", Log.DEBUG),
    INFO("info", Log.INFO),
    WARNING("warning", Log.WARN),
    ERROR("error", Log.ERROR),
}

class EnvelopeLog(var ring: NativeRingLog?) {
    companion object {
        /** The logcat tag of every native envelope record. */
        const val TAG = "mpx_transfer"
    }

    /** Takes a record while Dart is attached; null while it is not. */
    var sink: ((Map<String, Any?>) -> Unit)? = null

    /**
     * Records [op] (an `EnvelopeOp` name) at [level] with [fields] and the job [jobId] it concerns. A record the
     * Dart side reports itself (a start's refusal, an end it hears as a seam
     * event) goes to logcat only, with [bridge] false.
     */
    fun record(
        level: EnvelopeLevel,
        op: String,
        jobId: String? = null,
        fields: Map<String, Any> = emptyMap(),
        timeMs: Long = System.currentTimeMillis(),
        bridge: Boolean = true,
    ) {
        logcat(level, op, jobId, fields)
        if (!bridge) return
        val record = mapOf(
            "time" to timeMs,
            "level" to level.wireName,
            "op" to op,
            "jobId" to jobId,
            "fields" to fields,
        )
        val sink = sink
        if (sink != null) {
            sink(record)
            return
        }
        val json = JSONObject()
            .put("time", timeMs)
            .put("level", level.wireName)
            .put("op", op)
            .put("fields", JSONObject(fields))
        if (jobId != null) json.put("jobId", jobId)
        try {
            ring?.append(json.toString())
        } catch (error: Exception) {
            // The ring is the record's last stop; logcat already holds it.
            Log.w(TAG, "envelope ring write failed: ${error.javaClass.simpleName}")
        }
    }

    /** The ring's records as the channel's maps, oldest first; it is emptied. */
    fun drainRing(): List<Map<String, Any?>> {
        val lines = try {
            ring?.drain() ?: emptyList()
        } catch (error: Exception) {
            Log.w(TAG, "envelope ring read failed: ${error.javaClass.simpleName}")
            emptyList()
        }
        return lines.mapNotNull { line ->
            try {
                val json = JSONObject(line)
                val fields = json.optJSONObject("fields")
                mapOf(
                    "time" to json.getLong("time"),
                    "level" to json.getString("level"),
                    "op" to json.getString("op"),
                    "jobId" to if (json.has("jobId")) json.getString("jobId") else null,
                    "fields" to buildMap {
                        fields?.keys()?.forEach { key -> put(key, fields.get(key)) }
                    },
                )
            } catch (error: Exception) {
                // A torn last line after a kill mid-write.
                Log.w(TAG, "envelope ring record dropped: ${error.javaClass.simpleName}")
                null
            }
        }
    }

    /**
     * Writes [message] to logcat only: a failure of the envelope's own
     * machinery that has no `EnvelopeOp`, named by the error's class and
     * never its message, which may carry a path.
     */
    fun note(level: EnvelopeLevel, message: String, error: Throwable? = null) {
        val text = if (error == null) message else "$message: ${error.javaClass.simpleName}"
        Log.println(level.priority, TAG, text)
    }

    private fun logcat(level: EnvelopeLevel, op: String, jobId: String?, fields: Map<String, Any>) {
        val message = buildString {
            append("envelope.").append(op)
            if (jobId != null) append(" job=").append(jobId)
            for ((key, value) in fields) append(' ').append(key).append('=').append(value)
        }
        Log.println(level.priority, TAG, message)
    }
}
