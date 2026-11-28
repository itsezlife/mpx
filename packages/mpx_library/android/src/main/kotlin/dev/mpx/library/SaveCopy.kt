package dev.mpx.library

import java.io.InputStream
import java.io.OutputStream

/** A saved item as the platform names it. */
internal data class Published(val ref: String, val renamed: Boolean)

/**
 * A destination that exists before its bytes and is invisible until
 * [publish]: a pending MediaStore row, a hidden file, a created document.
 */
internal interface PendingWrite {
    val output: OutputStream

    /** Makes the written bytes the saved item; [output] is closed first. */
    fun publish(): Published

    /** Removes what was created; [output] is closed first. */
    fun discard()
}

/**
 * One item's copy from [source] into [target], a step at a time so the Dart
 * side can report progress and stop between steps.
 *
 * The target is created (inserted pending) before the first byte and
 * published only after the last; any failure mid-copy, and an [abort],
 * discard it, so no half-written item is left. [onPublished] runs once
 * after publishing (a moved source is deleted there).
 */
internal class SaveCopy(
    private val source: InputStream,
    val total: Long?,
    private val target: PendingWrite,
    private val buffer: Int = 64 * 1024,
    private val onPublished: () -> Unit = {},
) {
    var written = 0L
        private set

    /** Whether the copy was published or discarded. */
    var ended = false
        private set

    /** Copies up to [budget] bytes; true once the source is exhausted. */
    fun step(budget: Int): Boolean {
        check(!ended) { "the copy has ended" }
        val chunk = ByteArray(buffer)
        var left = budget
        try {
            while (left > 0) {
                val read = source.read(chunk, 0, minOf(chunk.size, left))
                if (read < 0) return true
                target.output.write(chunk, 0, read)
                written += read
                left -= read
            }
            return false
        } catch (error: Throwable) {
            abort()
            throw error
        }
    }

    fun publish(): Published {
        check(!ended) { "the copy has ended" }
        try {
            runCatching { source.close() }
            // A flush that fails here (no space) fails the save.
            target.output.close()
            val published = target.publish()
            ended = true
            onPublished()
            return published
        } catch (error: Throwable) {
            abort()
            throw error
        }
    }

    /** Discards the target; a second call does nothing. */
    fun abort() {
        if (ended) return
        ended = true
        // What is being thrown away cannot fail usefully on close.
        runCatching { source.close() }
        runCatching { target.output.close() }
        target.discard()
    }
}
