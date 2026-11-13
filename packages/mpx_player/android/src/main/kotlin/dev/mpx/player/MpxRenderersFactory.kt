package dev.mpx.player

import android.content.Context
import android.media.MediaCrypto
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

/**
 * ExoPlayer's renderers, with a video renderer that asks the decoder to
 * tone-map HDR to SDR.
 *
 * Speed stays on the audio sink's software time-stretching, which takes a
 * new speed once the audio already processed has played out (about half a
 * second). AudioTrack playback params would apply it at once, but on a
 * device a quick run of speed changes left the track's clock standing
 * still: the player reported playing and its position never moved again,
 * with no error. The Dart playhead follows the rate it measures, so the bar
 * shows the late change as it happens.
 *
 * Flutter's texture has no HDR path: an HDR frame shown as is looks washed
 * out. From API 31 a decoder can tone-map itself when the configuration asks
 * for an SDR transfer; one that cannot ignores the key, and below API 31 HDR
 * shows SDR-clipped.
 */
@UnstableApi
internal class MpxRenderersFactory(context: Context) : DefaultRenderersFactory(context) {
    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        out.add(
            SdrVideoRenderer(
                context,
                mediaCodecSelector,
                allowedVideoJoiningTimeMs,
                enableDecoderFallback,
                eventHandler,
                eventListener,
            ),
        )
    }
}

@UnstableApi
private class SdrVideoRenderer(
    context: Context,
    selector: MediaCodecSelector,
    joiningTimeMs: Long,
    decoderFallback: Boolean,
    handler: Handler,
    listener: VideoRendererEventListener,
) : MediaCodecVideoRenderer(
        context,
        selector,
        joiningTimeMs,
        decoderFallback,
        handler,
        listener,
        DefaultRenderersFactory.MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY,
    ) {
    override fun getMediaCodecConfiguration(
        codecInfo: MediaCodecInfo,
        format: Format,
        crypto: MediaCrypto?,
        codecOperatingRate: Float,
    ): MediaCodecAdapter.Configuration {
        val configuration =
            super.getMediaCodecConfiguration(codecInfo, format, crypto, codecOperatingRate)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && isHdr(format)) {
            configuration.mediaFormat.setInteger(
                MediaFormat.KEY_COLOR_TRANSFER_REQUEST,
                MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
            )
        }
        return configuration
    }

    private fun isHdr(format: Format): Boolean {
        val transfer = format.colorInfo?.colorTransfer ?: return false
        return transfer == C.COLOR_TRANSFER_ST2084 || transfer == C.COLOR_TRANSFER_HLG
    }
}
