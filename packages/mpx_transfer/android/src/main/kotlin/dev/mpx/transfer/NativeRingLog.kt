package dev.mpx.transfer

import java.io.File

/**
 * The envelope's records written while Dart is not running: one line per
 * record in [file], at most [maxBytes] on disk. When a record would pass the
 * limit the oldest lines go, down to half of it, so a long run without Dart
 * rewrites the file once per half-limit of records rather than at every one.
 *
 * The next start [drain]s it: every line, oldest first, and the file is
 * gone.
 */
class NativeRingLog(private val file: File, val maxBytes: Long = DEFAULT_MAX_BYTES) {
    companion object {
        /** The ring's size on disk by default: 2 MiB. */
        const val DEFAULT_MAX_BYTES: Long = 2L * 1024 * 1024
    }

    init {
        require(maxBytes > 0) { "The ring needs room for a record: $maxBytes" }
    }

    /** Adds [line] (no line breaks) as the newest record. */
    @Synchronized
    fun append(line: String) {
        val record = (line.replace('\n', ' ') + "\n").toByteArray(Charsets.UTF_8)
        // A record larger than the ring is dropped: keeping it would leave
        // the ring over its limit, and nothing older would fit beside it.
        if (record.size > maxBytes) return
        file.parentFile?.mkdirs()
        if (file.length() + record.size > maxBytes) trimTo(maxBytes / 2 - record.size)
        file.appendBytes(record)
    }

    /** Every record, oldest first; the ring is empty afterwards. */
    @Synchronized
    fun drain(): List<String> {
        if (!file.exists()) return emptyList()
        val lines = file.readLines(Charsets.UTF_8).filter { it.isNotEmpty() }
        file.delete()
        return lines
    }

    /** Keeps the newest whole lines that fit in [budget] bytes. */
    private fun trimTo(budget: Long) {
        val kept = ArrayDeque<String>()
        var size = 0L
        for (line in file.readLines(Charsets.UTF_8).asReversed()) {
            if (line.isEmpty()) continue
            val bytes = line.toByteArray(Charsets.UTF_8).size + 1L
            if (size + bytes > budget) break
            kept.addFirst(line)
            size += bytes
        }
        file.writeText(kept.joinToString("") { "$it\n" }, Charsets.UTF_8)
    }
}
