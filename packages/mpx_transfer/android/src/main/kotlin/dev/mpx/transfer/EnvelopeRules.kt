package dev.mpx.transfer

import android.app.ApplicationExitInfo
import android.app.job.JobParameters

/**
 * The envelope kinds this platform offers, by their names on the channel
 * (the Dart side's `TransferEnvelopeKind`).
 */
enum class EnvelopeKind(val wireName: String) {
    /** A user-initiated data transfer job: Android 14 (API 34) and later. */
    UIDT("uidt"),

    /** A `dataSync` foreground service: before Android 14. */
    DATA_SYNC("dataSync"),
}

/**
 * What the shared notification shows for the progress the engine mirrored:
 * the bar ([max] / [progress], or [indeterminate] when the size is unknown)
 * and its two text lines.
 */
data class ProgressView(
    val max: Int,
    val progress: Int,
    val indeterminate: Boolean,
    val fraction: Double?,
    val contentText: String?,
    val subText: String?,
)

/**
 * The pure rules of the Android envelope: which kind holds the process on
 * an API level, what the notification shows for mirrored progress, and why
 * the system ended a job or the process. Kept free of Android services so
 * the JVM unit tests run them.
 */
object EnvelopeRules {
    /** The first API level with user-initiated data transfer jobs. */
    const val UIDT_MIN_SDK = 34

    /** The notification bar's scale: whole per-mille steps. */
    const val PROGRESS_MAX = 1000

    /** The kind that holds the process on [sdkInt]. */
    fun kindFor(sdkInt: Int): EnvelopeKind =
        if (sdkInt >= UIDT_MIN_SDK) EnvelopeKind.UIDT else EnvelopeKind.DATA_SYNC

    /**
     * The notification's view of [done] of [total] bytes (null: a size is
     * unknown), with the host's [text] and the Dart side's [progressText].
     * The bytes are never counted here; they are the engine's.
     *
     * Without a progress text the bar stands alone under [text]. With both,
     * [text] is the content line and the progress text the header's sub
     * text; with only the progress text it takes the content line.
     */
    fun progressViewOf(done: Long, total: Long?, text: String?, progressText: String?): ProgressView {
        val fraction = if (total != null && total > 0) {
            (done.coerceAtLeast(0).toDouble() / total).coerceIn(0.0, 1.0)
        } else {
            null
        }
        val contentText = text ?: progressText
        val subText = if (text != null) progressText else null
        return ProgressView(
            max = PROGRESS_MAX,
            progress = fraction?.let { (it * PROGRESS_MAX).toInt() } ?: 0,
            indeterminate = fraction == null,
            fraction = fraction,
            contentText = contentText,
            subText = subText,
        )
    }

    /**
     * The Dart side's `TransferEnvelopeEndCause` for a job stopped with
     * [stopReason] (`JobParameters.STOP_REASON_*`): the time limit for a
     * timeout, a stop for anything else (a quota, an unmet constraint, the
     * user's Task Manager stop).
     */
    fun causeForStopReason(stopReason: Int): String = when (stopReason) {
        JobParameters.STOP_REASON_TIMEOUT -> "timeLimit"
        else -> "stop"
    }

    /**
     * The cause for a process that ended with an envelope live, from its
     * exit record's `ApplicationExitInfo.REASON_*`.
     */
    fun causeForExitReason(exitReason: Int): String = when (exitReason) {
        ApplicationExitInfo.REASON_LOW_MEMORY -> "lowMemory"
        else -> "stop"
    }
}
