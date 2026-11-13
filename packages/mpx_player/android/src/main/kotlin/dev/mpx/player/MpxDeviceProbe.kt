package dev.mpx.player

import android.app.ActivityManager
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecDecoderException
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer

/**
 * What the device decodes, for the prepared-player budget and the choice of
 * a quality, plus the video codecs whose decoder failed here before.
 *
 * Decoders lie about support, so a video decoder that fails to start or to
 * decode is remembered (in the app's preferences) and that codec is not
 * chosen again on this device.
 */
@UnstableApi
internal class MpxDeviceProbe(private val context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    /** The video codecs whose decoder failed on this device. */
    val failedCodecs: Set<String>
        get() = preferences.getStringSet(FAILED_CODECS, emptySet()) ?: emptySet()

    /**
     * The video MIME type whose decoder [error] says failed, remembered for
     * good; null when [error] is not a video decoder failure.
     */
    fun failedCodecOf(error: PlaybackException, videoMime: String?): String? {
        var cause: Throwable? = error.cause
        var mime: String? = null
        while (cause != null && mime == null) {
            mime =
                when (cause) {
                    is MediaCodecRenderer.DecoderInitializationException -> cause.mimeType
                    is MediaCodecDecoderException -> cause.codecInfo?.mimeType ?: videoMime
                    else -> null
                }
            cause = cause.cause
        }
        if (mime == null || !mime.startsWith("video/")) return null
        preferences.edit().putStringSet(FAILED_CODECS, failedCodecs + mime).apply()
        return mime
    }

    fun probe(): NativeDeviceProbe {
        val activities = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also { activities.getMemoryInfo(it) }
        val performanceClass =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Build.VERSION.MEDIA_PERFORMANCE_CLASS.takeIf { it > 0 }?.toLong()
            } else {
                null
            }
        return NativeDeviceProbe(
            lowRam = activities.isLowRamDevice,
            totalMemoryBytes = memory.totalMem,
            cpuCount = Runtime.getRuntime().availableProcessors().toLong(),
            memoryClassMb = activities.memoryClass.toLong(),
            performanceClass = performanceClass,
            decoders = decoders(),
            // ExoPlayer sniffs MP4, WebM and Matroska; HLS opens by its MIME type.
            containers = emptyList(),
            failedCodecs = failedCodecs.toList(),
        )
    }

    private fun decoders(): List<NativeDecoderInfo> {
        val found = ArrayList<NativeDecoderInfo>()
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (info.isEncoder) continue
            for (type in info.supportedTypes) {
                val mime = PROBED.firstOrNull { it.equals(type, ignoreCase = true) } ?: continue
                val instances =
                    try {
                        info.getCapabilitiesForType(type).maxSupportedInstances
                    } catch (_: IllegalArgumentException) {
                        0
                    }
                found.add(
                    NativeDecoderInfo(
                        mimeType = mime,
                        hardware = isHardware(info),
                        maxInstances = instances.toLong(),
                    ),
                )
            }
        }
        return found
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
        // Before API 29 the platform does not say; software codecs carry
        // these well-known name prefixes.
        val name = info.name.lowercase()
        return SOFTWARE_PREFIXES.none { name.startsWith(it) }
    }

    companion object {
        private const val PREFERENCES = "dev.mpx.player"
        private const val FAILED_CODECS = "failed_video_codecs"
        private val PROBED = listOf("video/avc", "video/hevc", "video/x-vnd.on2.vp9", "video/av01")
        private val SOFTWARE_PREFIXES = listOf("omx.google.", "c2.android.", "c2.google.", "omx.ffmpeg.")
    }
}
