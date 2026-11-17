package dev.mpx.player

import android.os.Build
import android.os.Trace

/**
 * Marks of a player's way to its first frame in the system trace, under the
 * names the Dart side uses: `mpx.player <stage> p<id>`, with an optional
 * detail after the id. A [mark] is a zero-length section; a [section] spans
 * the work it wraps, on the thread that does it.
 *
 * Always on: when the app is not traced a mark costs one check (API 29 and
 * up) or one empty section below that, a handful per player.
 */
internal object MpxPlayerTrace {
    // The platform caps a section's name at 127 characters.
    private const val MAX_NAME = 127

    val enabled: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Trace.isEnabled()

    fun name(stage: String, id: Long, detail: String?): String {
        val name =
            if (detail == null) "mpx.player $stage p$id" else "mpx.player $stage p$id $detail"
        return if (name.length <= MAX_NAME) name else name.substring(0, MAX_NAME)
    }

    fun mark(stage: String, id: Long, detail: String? = null) {
        if (!enabled) return
        Trace.beginSection(name(stage, id, detail))
        Trace.endSection()
    }

    inline fun <T> section(stage: String, id: Long, detail: String? = null, block: () -> T): T {
        val traced = enabled
        if (traced) Trace.beginSection(name(stage, id, detail))
        try {
            return block()
        } finally {
            if (traced) Trace.endSection()
        }
    }
}
