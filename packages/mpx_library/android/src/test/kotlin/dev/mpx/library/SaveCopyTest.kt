package dev.mpx.library

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream

class SaveCopyTest {
    /** A pending row that records what happens to it, in order. */
    private class Row(private val failAfter: Int = Int.MAX_VALUE) : PendingWrite {
        val log = mutableListOf<String>()
        val bytes = ByteArrayOutputStream()

        override val output: OutputStream = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

            override fun write(b: ByteArray, off: Int, len: Int) {
                if (bytes.size() + len > failAfter) throw IOException("write failed: ENOSPC")
                bytes.write(b, off, len)
            }

            override fun close() {
                log += "closed"
            }
        }

        override fun publish(): Published {
            log += "published"
            return Published("content://media/external/images/media/7", renamed = false)
        }

        override fun discard() {
            log += "discarded"
        }
    }

    private val source = ByteArray(10) { it.toByte() }

    @Test
    fun copiesInStepsAndPublishesOnlyAfterTheLastByte() {
        val row = Row()
        val copy = SaveCopy(ByteArrayInputStream(source), source.size.toLong(), row, buffer = 2)

        assertFalse(copy.step(budget = 4))
        assertEquals(4L, copy.written)
        assertTrue("nothing published mid-copy", row.log.isEmpty())
        assertFalse(copy.step(budget = 4))
        assertTrue(copy.step(budget = 4))
        assertEquals(10L, copy.written)

        val published = copy.publish()

        assertEquals("content://media/external/images/media/7", published.ref)
        assertArrayEquals(source, row.bytes.toByteArray())
        assertEquals(listOf("closed", "published"), row.log)
    }

    @Test
    fun anAbortDiscardsThePendingRowAndNeverPublishes() {
        val row = Row()
        val copy = SaveCopy(ByteArrayInputStream(source), source.size.toLong(), row, buffer = 2)
        copy.step(budget = 4)

        copy.abort()
        copy.abort()

        assertEquals(listOf("closed", "discarded"), row.log)
    }

    @Test
    fun aFailureMidCopyDiscardsTheRowAndRethrows() {
        val row = Row(failAfter = 5)
        val copy = SaveCopy(ByteArrayInputStream(source), source.size.toLong(), row, buffer = 2)
        try {
            copy.step(budget = 10)
            fail("the write failure is thrown")
        } catch (error: IOException) {
            assertEquals("ENOSPC", SaveErrors.codeOf(error))
        }
        assertEquals(listOf("closed", "discarded"), row.log)
    }

    @Test
    fun thePublishedHookRunsOnceAfterPublishing() {
        val row = Row()
        var after = 0
        val copy = SaveCopy(ByteArrayInputStream(source), null, row, onPublished = { after++ })
        assertTrue(copy.step(budget = 100))
        copy.publish()
        assertEquals(1, after)
    }
}
