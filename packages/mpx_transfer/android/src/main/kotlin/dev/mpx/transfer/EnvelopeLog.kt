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
class EnvelopeLog(var ring: NativeRingLog?) {
    companion object {
        /** The logcat tag of every native envelope record. */
        const val TAG = "mpx_transfer"
    }

    /** Takes a record while Dart is attached; null while it is not. */
    var sink: ((Map<String, Any?>) -> Unit)? = null

    /**
     * Records [op] (an `EnvelopeOp` name) at [level] (an `MpxEventLevel`
     * name) with [fields] and the job [jobId] it concerns. A record the
     * Dart side reports itself (a start's refusal, an end it hears as a seam
     * event) goes to logcat only, with [bridge] false.
     */
    fun record(
        level: String,
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
            "level" to level,
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
            .put("level", level)
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

    private fun logcat(level: String, op: String, jobId: String?, fields: Map<String, Any>) {
        val message = buildString {
            append("envelope.").append(op)
            if (jobId != null) append(" job=").append(jobId)
            for ((key, value) in fields) append(' ').append(key).append('=').append(value)
        }
        when (level) {
            "trace" -> Log.v(TAG, message)
            "debug" -> Log.d(TAG, message)
            "info" -> Log.i(TAG, message)
            "warning" -> Log.w(TAG, message)
            else -> Log.e(TAG, message)
        }
    }
}
