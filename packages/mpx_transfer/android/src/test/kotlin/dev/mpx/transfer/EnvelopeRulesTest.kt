package dev.mpx.transfer

import android.app.ApplicationExitInfo
import android.app.job.JobParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnvelopeRulesTest {
    @Test
    fun aUserInitiatedJobFromAndroid14ADataSyncServiceBelow() {
        assertEquals(EnvelopeKind.DATA_SYNC, EnvelopeRules.kindFor(24))
        assertEquals(EnvelopeKind.DATA_SYNC, EnvelopeRules.kindFor(33))
        assertEquals(EnvelopeKind.UIDT, EnvelopeRules.kindFor(34))
        assertEquals(EnvelopeKind.UIDT, EnvelopeRules.kindFor(36))
    }

    @Test
    fun theKindsCarryTheDartNames() {
        assertEquals("uidt", EnvelopeKind.UIDT.wireName)
        assertEquals("dataSync", EnvelopeKind.DATA_SYNC.wireName)
    }

    @Test
    fun theBarFollowsTheMirroredBytes() {
        val view = EnvelopeRules.progressViewOf(250, 1000, null, null)
        assertEquals(1000, view.max)
        assertEquals(250, view.progress)
        assertFalse(view.indeterminate)
        assertEquals(0.25, view.fraction!!, 0.0)
    }

    @Test
    fun anUnknownOrEmptySizeIsIndeterminate() {
        for (total in listOf<Long?>(null, 0L)) {
            val view = EnvelopeRules.progressViewOf(10, total, null, null)
            assertTrue(view.indeterminate)
            assertEquals(0, view.progress)
            assertNull(view.fraction)
        }
    }

    @Test
    fun theBarStaysInsideItsScale() {
        assertEquals(1000, EnvelopeRules.progressViewOf(2000, 1000, null, null).progress)
        assertEquals(0, EnvelopeRules.progressViewOf(-5, 1000, null, null).progress)
    }

    @Test
    fun withoutAProgressTextTheBarStandsUnderTheText() {
        val view = EnvelopeRules.progressViewOf(1, 2, "Sending", null)
        assertEquals("Sending", view.contentText)
        assertNull(view.subText)
        assertNull(EnvelopeRules.progressViewOf(1, 2, null, null).contentText)
    }

    @Test
    fun theProgressTextIsTheSubTextBesideATextAndTheLineWithout() {
        val both = EnvelopeRules.progressViewOf(1, 2, "Sending", "3 of 5 files")
        assertEquals("Sending", both.contentText)
        assertEquals("3 of 5 files", both.subText)
        val alone = EnvelopeRules.progressViewOf(1, 2, null, "3 of 5 files")
        assertEquals("3 of 5 files", alone.contentText)
        assertNull(alone.subText)
    }

    @Test
    fun aTimeoutIsTheTimeLimitAnyOtherStopAStop() {
        assertEquals("timeLimit", EnvelopeRules.causeForStopReason(JobParameters.STOP_REASON_TIMEOUT))
        assertEquals("stop", EnvelopeRules.causeForStopReason(JobParameters.STOP_REASON_QUOTA))
        assertEquals("stop", EnvelopeRules.causeForStopReason(JobParameters.STOP_REASON_USER))
        assertEquals("stop", EnvelopeRules.causeForStopReason(-1))
    }

    @Test
    fun aLowMemoryExitIsLowMemory() {
        assertEquals("lowMemory", EnvelopeRules.causeForExitReason(ApplicationExitInfo.REASON_LOW_MEMORY))
        assertEquals("stop", EnvelopeRules.causeForExitReason(ApplicationExitInfo.REASON_USER_REQUESTED))
    }
}
