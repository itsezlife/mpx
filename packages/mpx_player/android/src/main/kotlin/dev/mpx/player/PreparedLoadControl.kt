package dev.mpx.player

import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator

/**
 * [inner], except that a player that has not played yet stops loading once
 * it holds [aheadUs] of media or [bytes] of buffer: enough for its first
 * frame and a short start. A prepared, paused neighbour would otherwise fill
 * the whole forward buffer for an item nobody may play.
 *
 * The cap lifts for good the first time the player wants to play
 * (`playWhenReady`); ExoPlayer asks again on its next loop and loads as
 * usual from then on. A cap of 0 is none.
 */
@UnstableApi
internal class PreparedLoadControl(
    private val inner: LoadControl,
    private val aheadUs: Long,
    private val bytes: Int,
) : LoadControl {
    private var played = aheadUs <= 0 && bytes <= 0

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        if (parameters.playWhenReady) played = true
        if (!played) {
            if (aheadUs > 0 && parameters.bufferedDurationUs >= aheadUs) return false
            if (bytes > 0 &&
                inner.getAllocator(parameters.playerId).totalBytesAllocated >= bytes
            ) return false
        }
        return inner.shouldContinueLoading(parameters)
    }

    override fun onPrepared(playerId: PlayerId) = inner.onPrepared(playerId)

    override fun onTracksSelected(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        renderers: Array<out Renderer>,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) = inner.onTracksSelected(
        playerId,
        timeline,
        mediaPeriodId,
        renderers,
        trackGroups,
        trackSelections,
    )

    override fun onStopped(playerId: PlayerId) = inner.onStopped(playerId)

    override fun onReleased(playerId: PlayerId) = inner.onReleased(playerId)

    override fun getAllocator(playerId: PlayerId): Allocator = inner.getAllocator(playerId)

    override fun getBackBufferDurationUs(playerId: PlayerId): Long =
        inner.getBackBufferDurationUs(playerId)

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
        inner.retainBackBufferFromKeyframe(playerId)

    override fun shouldContinuePreloading(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        bufferedDurationUs: Long,
    ): Boolean = inner.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        inner.shouldStartPlayback(parameters)
}
