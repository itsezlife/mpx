package dev.mpx.transfer

import org.junit.Assert.assertEquals
import org.junit.Test

class EnvelopeLevelTest {
    @Test
    fun wireNamesAreTheDartLevelNames() {
        assertEquals(
            listOf("trace", "debug", "info", "warning", "error"),
            EnvelopeLevel.values().map { it.wireName },
        )
    }

    @Test
    fun eachLevelHasItsOwnLogcatPriority() {
        val priorities = EnvelopeLevel.values().map { it.priority }
        assertEquals(priorities.sorted(), priorities)
        assertEquals(priorities.size, priorities.toSet().size)
    }
}
