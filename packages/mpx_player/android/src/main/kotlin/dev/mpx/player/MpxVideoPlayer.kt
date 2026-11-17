package dev.mpx.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.view.TextureRegistry

/**
 * One ExoPlayer drawing into its own [TextureRegistry.SurfaceProducer] and
 * reading its bytes through the bytes cache's native reader: a progressive
 * file by its cache key, or an HLS stream whose parts Dart hands over one by
 * one ([parts]).
 *
 * Reports a whole snapshot to Dart on every change and every 100 ms while it
 * plays; Dart extrapolates the playhead in between and slews it onto each
 * report (the player's position lags the clock at speeds above 1, where the
 * audio is time-stretched). Every call is on
 * the main thread, where ExoPlayer's listeners run too.
 */
@UnstableApi
internal class MpxVideoPlayer(
    context: Context,
    val id: Long,
    source: NativePlayerSource,
    settings: NativePlayerSettings,
    private val producer: TextureRegistry.SurfaceProducer,
    renderers: RenderersFactory,
    parts: StreamParts,
    private val report: (NativePlayerSnapshot) -> Unit,
    private val failedCodecOf: (PlaybackException, String?) -> String?,
) : Player.Listener {
    private val readers = OpenReaders(source.readerApi)
    private val handler = Handler(Looper.getMainLooper())
    private val exo: ExoPlayer
    private var prepared = false
    private var firstFrame = false
    private var seekId = settings.seekId
    private var looping = settings.looping
    private var error: String? = null
    private var failedCodec: String? = null
    private var disposed = false
    private var surfaceSize: Pair<Int, Int>? = null

    private val tick =
        object : Runnable {
            override fun run() {
                if (disposed) return
                send()
                if (exo.isPlaying || exo.isLoading) handler.postDelayed(this, TICK_MS)
            }
        }

    // The decoders' set-up times, as marks in the system trace. Reported on
    // the main thread, after the fact: the detail says when (elapsed
    // realtime) and how long.
    private val decoders =
        object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) = MpxPlayerTrace.mark(
                "video-decoder",
                id,
                "init=${initializationDurationMs}ms at=${initializedTimestampMs}ms $decoderName",
            )

            override fun onAudioDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) = MpxPlayerTrace.mark(
                "audio-decoder",
                id,
                "init=${initializationDurationMs}ms at=${initializedTimestampMs}ms $decoderName",
            )
        }

    // The surface the player draws into now; null while the engine has taken
    // it back. Declared before init, which attaches the first one.
    private var surface: Surface? = null

    init {
        Log.d(TAG, "player $id create")
        val mediaSource = mediaSourceOf(source, parts)
        exo =
            MpxPlayerTrace.section("exo-build", id) {
                ExoPlayer.Builder(context, renderers)
                    .setLooper(Looper.getMainLooper())
                    // The Dart player pool owns audio focus and the noisy-output
                    // rule (one sound owner app-wide), so ExoPlayer handles neither.
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(C.USAGE_MEDIA)
                            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                            .build(),
                        /* handleAudioFocus= */ false,
                    )
                    .setHandleAudioBecomingNoisy(false)
                    .setLoadControl(loadControl())
                    .build()
            }
        exo.addListener(this)
        exo.addAnalyticsListener(decoders)
        exo.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        exo.playbackParameters = playbackParameters(settings.speed)
        exo.volume = settings.volume.toFloat()
        exo.playWhenReady = settings.playing
        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    if (!disposed) attachSurface("available")
                }

                // Under memory pressure the engine drops the surface and hands
                // a new one over on resume; the player must let go meanwhile.
                // Only the surface it holds is cleared: a cleanup that comes
                // after a newer surface was attached never clears that one.
                override fun onSurfaceCleanup() {
                    if (disposed) return
                    val held = surface ?: return
                    Log.d(TAG, "player $id clears surface $held")
                    exo.clearVideoSurface(held)
                    surface = null
                }
            },
        )
        attachSurface("create")
        MpxPlayerTrace.section("prepare", id) {
            exo.setMediaSource(mediaSource, settings.startAtUs / 1000)
            exo.prepare()
        }
        send()
    }

    // When playback starts: Media3's defaults wait for a second of media
    // before the first start and two after a stall, the thresholds of a
    // network stream it cannot see the cost of. Here every read is from the
    // bytes cache's sparse file, a local read once the bytes landed, and the
    // cache fetches ahead of the loader on its own: a tenth of a second
    // starts at once, as soon as the first frame and the first audio are
    // decoded. After a stall the network has proved slower than the media,
    // so a second of it is waited for (half the default), which keeps a slow
    // link from stalling again every few frames. The buffer it keeps
    // ahead is unchanged.
    private fun loadControl() =
        DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                DefaultLoadControl.DEFAULT_MIN_BUFFER_MS,
                DefaultLoadControl.DEFAULT_MAX_BUFFER_MS,
                START_BUFFER_MS,
                RESTART_BUFFER_MS,
            )
            .build()

    private fun mediaSourceOf(source: NativePlayerSource, parts: StreamParts): MediaSource {
        val playlist = source.playlistUrl
        val stream = source.streamId
        if (playlist != null && stream != null) {
            return HlsMediaSource.Factory(
                    StreamPartDataSource.Factory(parts, stream, source.readerApi, readers, id),
                )
                .createMediaSource(
                    MediaItem.Builder()
                        .setUri(Uri.parse(playlist))
                        .setMimeType(MimeTypes.APPLICATION_M3U8)
                        .build(),
                )
        }
        return ProgressiveMediaSource.Factory(
                HbcDataSource.Factory(source.readerApi, source.cacheKey, readers, id),
            )
            .createMediaSource(
                MediaItem.Builder()
                    .setUri(Uri.parse("$SCHEME://${Uri.encode(source.cacheKey)}"))
                    .setMimeType(source.mimeType)
                    .build(),
            )
    }

    private fun attachSurface(reason: String) {
        val next = producer.surface
        if (next === surface) return
        Log.d(TAG, "player $id surface $next ($reason), texture ${producer.id()}")
        surface = next
        MpxPlayerTrace.section("set-surface", id, reason) { exo.setVideoSurface(next) }
    }

    fun play() {
        if (disposed) return
        Log.d(TAG, "player $id play")
        // Playing at the end of a pass that does not loop starts it again.
        if (exo.playbackState == Player.STATE_ENDED) exo.seekTo(0)
        exo.playWhenReady = true
        send()
    }

    fun pause() {
        if (disposed) return
        Log.d(TAG, "player $id pause")
        exo.playWhenReady = false
        send()
    }

    fun seekTo(positionUs: Long, id: Long) {
        if (disposed) return
        // A read blocked on bytes the seek no longer needs would hold the
        // loader until they land.
        readers.cancelAll()
        seekId = id
        Log.d(TAG, "player ${this.id} seek ${positionUs / 1000} ms")
        exo.seekTo(positionUs / 1000)
        send()
    }

    fun setSpeed(speed: Double) {
        if (disposed) return
        Log.d(TAG, "player $id speed $speed")
        exo.playbackParameters = playbackParameters(speed)
        send()
    }

    // A faster pass lowers the pitch a little, so speech sped up does not
    // sound thin.
    private fun playbackParameters(speed: Double) =
        PlaybackParameters(speed.toFloat(), if (speed > 1.0) FAST_PITCH else 1f)

    fun setLooping(looping: Boolean) {
        if (disposed) return
        this.looping = looping
        exo.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        send()
    }

    fun setVolume(volume: Double) {
        if (disposed) return
        exo.volume = volume.toFloat()
        send()
    }

    /** Whether it plays with sound now. */
    val isAudible: Boolean
        get() = !disposed && exo.isPlaying && exo.volume > 0f

    /** The ExoPlayer, for a media session. */
    val player: Player
        get() = exo

    /** The picture's shown aspect ratio, or null before the first format. */
    val aspectRatio: Pair<Int, Int>?
        get() {
            val format = exo.videoFormat ?: return null
            if (format.width <= 0 || format.height <= 0) return null
            val odd = (format.rotationDegrees / 90) % 2 != 0
            return if (odd) format.height to format.width else format.width to format.height
        }

    fun dispose() {
        if (disposed) return
        Log.d(TAG, "player $id release")
        disposed = true
        handler.removeCallbacks(tick)
        // Wake the loader before release waits for it.
        readers.cancelAll()
        exo.removeListener(this)
        exo.release()
        producer.release()
    }

    // --- Player.Listener ---------------------------------------------------

    override fun onPlaybackStateChanged(playbackState: Int) {
        Log.d(TAG, "player $id state $playbackState")
        if (playbackState == Player.STATE_READY) {
            if (!prepared) MpxPlayerTrace.mark("ready", id)
            prepared = true
        }
        send()
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        send()
        handler.removeCallbacks(tick)
        if (isPlaying) handler.postDelayed(tick, TICK_MS)
    }

    override fun onIsLoadingChanged(isLoading: Boolean) {
        if (isLoading && !exo.isPlaying) {
            handler.removeCallbacks(tick)
            handler.postDelayed(tick, TICK_MS)
        }
    }

    override fun onPositionDiscontinuity(
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int,
    ) = send()

    override fun onVideoSizeChanged(videoSize: VideoSize) = send()

    override fun onRenderedFirstFrame() {
        if (!firstFrame) MpxPlayerTrace.mark("first-frame", id)
        firstFrame = true
        send()
    }

    override fun onPlayerError(error: PlaybackException) {
        // The whole throwable goes to the log: the snapshot carries one line
        // to Dart, and a failure seen only on a device needs its cause chain.
        Log.e(TAG, "player $id failed: ${error.errorCodeName}: ${error.message}", error)
        this.error = "${error.errorCodeName}: ${error.message}"
        failedCodec = failedCodecOf(error, exo.videoFormat?.sampleMimeType)
        send()
    }

    // --- Snapshot ----------------------------------------------------------

    private fun send() {
        if (disposed) return
        report(snapshot())
    }

    private fun snapshot(): NativePlayerSnapshot {
        val failed = error != null
        val state = exo.playbackState
        val phase =
            when {
                failed -> NativePlayerPhase.FAILED
                !prepared -> NativePlayerPhase.PREPARING
                state == Player.STATE_ENDED -> NativePlayerPhase.ENDED
                // Stalled while it could play; a paused player waiting for
                // bytes after a seek still shows its frame.
                state == Player.STATE_BUFFERING && exo.playWhenReady -> NativePlayerPhase.BUFFERING
                else -> NativePlayerPhase.READY
            }
        val format = exo.videoFormat
        var width: Long? = null
        var height: Long? = null
        var quarterTurns = 0L
        if (format != null && format.width > 0 && format.height > 0) {
            val turns = ((format.rotationDegrees / 90) % 4 + 4) % 4
            // The zero-copy (ImageReader) producer ignores the buffer's
            // transform: the picture comes unrotated and Dart turns it. The
            // copying producer below API 29 applies it, and the picture is
            // upright at its shown size.
            if (producer.handlesCropAndRotation()) {
                val odd = turns % 2 != 0
                width = (if (odd) format.height else format.width).toLong()
                height = (if (odd) format.width else format.height).toLong()
            } else {
                width = format.width.toLong()
                height = format.height.toLong()
                quarterTurns = turns.toLong()
            }
            resizeSurface(format.width, format.height)
        }
        val duration = exo.duration
        val positionUs = exo.currentPosition * 1000
        return NativePlayerSnapshot(
            playerId = id,
            phase = phase,
            positionUs = positionUs,
            sampledAtUs = SystemClock.elapsedRealtimeNanos() / 1000,
            advancing = !failed && exo.isPlaying,
            quarterTurns = quarterTurns,
            firstFrameRendered = firstFrame && !failed,
            buffered =
                if (failed || !prepared) emptyList()
                else listOf(positionUs, maxOf(positionUs, exo.bufferedPosition * 1000)),
            seekId = seekId,
            durationUs = if (duration == C.TIME_UNSET || failed) null else duration * 1000,
            width = if (failed) null else width,
            height = if (failed) null else height,
            textureId = if (failed) null else producer.id(),
            error = error,
            failedCodec = failedCodec,
        )
    }

    private fun resizeSurface(width: Int, height: Int) {
        if (surfaceSize == width to height) return
        surfaceSize = width to height
        producer.setSize(width, height)
    }

    companion object {
        const val SCHEME = "mpx-hbc"
        private const val TAG = "mpx_player"
        private const val TICK_MS = 100L
        private const val FAST_PITCH = 0.98f
        private const val START_BUFFER_MS = 100
        private const val RESTART_BUFFER_MS = 1000
    }
}
