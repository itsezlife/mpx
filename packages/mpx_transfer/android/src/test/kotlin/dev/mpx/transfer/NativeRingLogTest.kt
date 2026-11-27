package dev.mpx.transfer

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeRingLogTest {
    private fun ring(maxBytes: Long = NativeRingLog.DEFAULT_MAX_BYTES): Pair<NativeRingLog, File> {
        val file = File(Files.createTempDirectory("ring").toFile(), "log/envelope_log.jsonl")
        return NativeRingLog(file, maxBytes) to file
    }

    @Test
    fun twoMebibytesByDefault() {
        assertEquals(2L * 1024 * 1024, NativeRingLog.DEFAULT_MAX_BYTES)
        assertEquals(2L * 1024 * 1024, ring().first.maxBytes)
    }

    @Test
    fun drainAnswersOldestFirstAndEmptiesIt() {
        val (log, file) = ring()
        log.append("a")
        log.append("b")
        assertEquals(listOf("a", "b"), log.drain())
        assertFalse(file.exists())
        assertEquals(emptyList<String>(), log.drain())
    }

    @Test
    fun aRecordKeepsToOneLine() {
        val (log, _) = ring()
        log.append("a\nb")
        assertEquals(listOf("a b"), log.drain())
    }

    @Test
    fun pastTheLimitTheOldestGoDownToHalf() {
        val (log, file) = ring(maxBytes = 100)
        // Ten bytes per record with its line break.
        for (index in 0 until 10) log.append("record-%02d".format(index))
        assertEquals(100, file.length())
        log.append("newest--1")
        assertTrue(file.length() <= 100)
        val kept = log.drain()
        assertEquals("newest--1", kept.last())
        assertEquals(5, kept.size)
        assertEquals("record-06", kept.first())
    }

    @Test
    fun aRecordLargerThanTheRingIsDropped() {
        val (log, _) = ring(maxBytes = 8)
        log.append("x".repeat(20))
        log.append("ok")
        assertEquals(listOf("ok"), log.drain())
    }
}
