package dev.mpx.player

import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.LoadControl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

/**
 * Guards [PreparedLoadControl] against a Media3 release that calls an
 * overload it leaves to the interface's default, which throws: every
 * method of [LoadControl] must be declared by the wrapper.
 */
class PreparedLoadControlTest {
    @Test
    fun forwardsEveryLoadControlMethod() {
        val declared = PreparedLoadControl::class.java.declaredMethods
            .map { it.name to it.parameterTypes.toList() }
            .toSet()
        val missing = LoadControl::class.java.methods
            .filter { !Modifier.isStatic(it.modifiers) }
            .map { it.name to it.parameterTypes.toList() }
            .filter { it !in declared }
            .map { (name, types) -> "$name(${types.joinToString { t -> t.simpleName }})" }
        assertEquals(emptyList<String>(), missing)
    }

    @Test
    fun aPlayerNotReadyLoadsPastTheCapUntilItsFirstFrame() {
        var ready = false
        // An inner control that always wants more: only the cap says no.
        val inner = object : LoadControl {
            override fun shouldContinueLoading(parameters: LoadControl.Parameters) = true
            override fun getAllocator(playerId: PlayerId): Allocator = throw UnsupportedOperationException()
            override fun shouldStartPlayback(parameters: LoadControl.Parameters) = true
        }
        val control = PreparedLoadControl(
            inner,
            aheadUs = 2_000_000,
            bytes = 0,
            ready = { ready },
        )
        fun parameters(bufferedUs: Long) = LoadControl.Parameters(
            PlayerId.UNSET,
            Timeline.EMPTY,
            MediaSource.MediaPeriodId(Any()),
            0,
            bufferedUs,
            1f,
            false,
            false,
            C.TIME_UNSET,
            C.TIME_UNSET,
        )
        // Three seconds buffered, past the two-second cap, paused.
        assertTrue(control.shouldContinueLoading(parameters(3_000_000)))
        ready = true
        assertFalse(control.shouldContinueLoading(parameters(3_000_000)))
    }
}
