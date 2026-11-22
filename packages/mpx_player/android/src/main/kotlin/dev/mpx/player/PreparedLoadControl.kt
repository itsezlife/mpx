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
 * The cap holds only once the player is [ready] (its first frame shown):
 * before that it loads as [inner] says. A capped player that is not ready
 * stays not ready (a paused player waits for its renderers, and they wait
 * for media), so a video whose first frame needs more than the cap (an 8K
 * clip at 80 Mbit/s fills 2 MiB in a fifth of a second, before its first
 * picture is decoded) would wait forever, spinning, until a play lifted the
 * cap. [ready] is read on the playback thread.
 *
 * The cap lifts for good the first time the player wants to play
 * (`playWhenReady`); ExoPlayer asks again on its next loop and loads as
 * usual from then on. A cap of 0 is none.
 *
 * Every method of [LoadControl], each overload included, is forwarded to
 * [inner]: the interface's defaults of the overloads a player does not use
 * throw, and which overload a Media3 release calls changes between releases
 * (`PreparedLoadControlTest` checks that none is left to its default).
 */
@UnstableApi
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
internal class PreparedLoadControl(
    private val inner: LoadControl,
    private val aheadUs: Long,
    private val bytes: Int,
    private val ready: () -> Boolean = { true },
) : LoadControl {
    private var played = aheadUs <= 0 && bytes <= 0

    // --- Loading (the cap) ---

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        if (parameters.playWhenReady) played = true
        if (!played && ready()) {
            if (aheadUs > 0 && parameters.bufferedDurationUs >= aheadUs) return false
            if (bytes > 0 &&
                inner.getAllocator(parameters.playerId).totalBytesAllocated >= bytes
            ) return false
        }
        return inner.shouldContinueLoading(parameters)
    }

    // The older form knows neither the player nor `playWhenReady`: only the
    // duration cap applies until a newer call has seen the player play.
    override fun shouldContinueLoading(
        playbackPositionUs: Long,
        bufferedDurationUs: Long,
        playbackSpeed: Float,
    ): Boolean {
        if (!played && ready() && aheadUs > 0 && bufferedDurationUs >= aheadUs) return false
        return inner.shouldContinueLoading(playbackPositionUs, bufferedDurationUs, playbackSpeed)
    }

    override fun shouldContinuePreloading(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        bufferedDurationUs: Long,
    ): Boolean = inner.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

    // --- Playback start ---

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        inner.shouldStartPlayback(parameters)

    override fun shouldStartPlayback(
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        bufferedDurationUs: Long,
        playbackSpeed: Float,
        rebuffering: Boolean,
        targetLiveOffsetUs: Long,
    ): Boolean = inner.shouldStartPlayback(
        timeline,
        mediaPeriodId,
        bufferedDurationUs,
        playbackSpeed,
        rebuffering,
        targetLiveOffsetUs,
    )

    override fun shouldStartPlayback(
        bufferedDurationUs: Long,
        playbackSpeed: Float,
        rebuffering: Boolean,
        targetLiveOffsetUs: Long,
    ): Boolean = inner.shouldStartPlayback(
        bufferedDurationUs,
        playbackSpeed,
        rebuffering,
        targetLiveOffsetUs,
    )

    // --- Lifecycle ---

    override fun onPrepared(playerId: PlayerId) = inner.onPrepared(playerId)

    override fun onPrepared() = inner.onPrepared()

    override fun onTracksSelected(
        parameters: LoadControl.Parameters,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) = inner.onTracksSelected(parameters, trackGroups, trackSelections)

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

    override fun onTracksSelected(
        timeline: Timeline,
        mediaPeriodId: MediaSource.MediaPeriodId,
        renderers: Array<out Renderer>,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) = inner.onTracksSelected(timeline, mediaPeriodId, renderers, trackGroups, trackSelections)

    override fun onTracksSelected(
        renderers: Array<out Renderer>,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) = inner.onTracksSelected(renderers, trackGroups, trackSelections)

    override fun onStopped(playerId: PlayerId) = inner.onStopped(playerId)

    override fun onStopped() = inner.onStopped()

    override fun onReleased(playerId: PlayerId) = inner.onReleased(playerId)

    override fun onReleased() = inner.onReleased()

    // --- Buffer ---

    override fun getAllocator(playerId: PlayerId): Allocator = inner.getAllocator(playerId)

    override fun getBackBufferDurationUs(playerId: PlayerId): Long =
        inner.getBackBufferDurationUs(playerId)

    override fun getBackBufferDurationUs(): Long = inner.backBufferDurationUs

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
        inner.retainBackBufferFromKeyframe(playerId)

    override fun retainBackBufferFromKeyframe(): Boolean = inner.retainBackBufferFromKeyframe()
}
