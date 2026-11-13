package dev.mpx.capture

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.MethodCall
import java.io.File

/** One compression as the Dart side planned it. */
class CompressionRequest(
    val job: Int,
    val source: String,
    val output: String,
    /** Output frame as displayed (after the track's rotation). */
    val width: Int,
    val height: Int,
    val videoBitrate: Int,
    val audioBitrate: Int,
    val audioChannels: Int,
    val passthrough: Boolean,
    val durationUs: Long,
) {
    companion object {
        fun from(call: MethodCall): CompressionRequest {
            fun <T> need(key: String): T =
                call.argument<T>(key) ?: throw CaptureException.failed("compress: missing $key")
            return CompressionRequest(
                job = need("job"),
                source = need("source"),
                output = need("output"),
                width = need("width"),
                height = need("height"),
                videoBitrate = need("videoBitrate"),
                audioBitrate = need("audioBitrate"),
                audioChannels = need("audioChannels"),
                passthrough = call.argument<Boolean>("passthrough") ?: false,
                durationUs = call.argument<Number>("durationUs")?.toLong() ?: 0L,
            )
        }
    }
}

/**
 * Runs compressions through Media3 Transformer, one at a time in the order
 * they were asked for. Transformer wants one application thread, so every
 * call here runs on the main looper.
 */
@OptIn(UnstableApi::class)
class CaptureTranscoder(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<CompressionRequest>()
    private var running: Running? = null

    private class Running(val request: CompressionRequest, val transformer: Transformer) {
        var finished = false
    }

    fun enqueue(request: CompressionRequest) {
        pending.addLast(request)
        startNext()
    }

    fun cancel(job: Int) {
        if (pending.removeAll { it.job == job }) return
        val current = running ?: return
        if (current.request.job != job) return
        current.finished = true
        current.transformer.cancel()
        File(current.request.output).delete()
        running = null
        startNext()
    }

    fun cancelAll() {
        pending.clear()
        running?.let { cancel(it.request.job) }
    }

    private fun startNext() {
        if (running != null) return
        val request = pending.removeFirstOrNull() ?: return
        try {
            start(request)
        } catch (error: Exception) {
            File(request.output).delete()
            emit(CaptureException.failed(error.message ?: "$error").event(request.job))
            startNext()
        }
    }

    private fun start(request: CompressionRequest) {
        File(request.output).delete()
        lateinit var current: Running
        val builder = Transformer.Builder(context).setMuxerFactory(muxerFor(request))
        // Requested encoder settings make Transformer re-encode, so a
        // passthrough keeps the defaults and the source's formats.
        if (!request.passthrough) {
            builder
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setEncoderFactory(encodersFor(request))
        }
        val transformer = builder
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    finish(current) { done(current.request, exportResult) }
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    finish(current) {
                        File(current.request.output).delete()
                        emit(
                            CaptureException.failed(
                                exportException.message ?: "export failed",
                            ).event(current.request.job),
                        )
                    }
                }
            })
            .build()
        current = Running(request, transformer)
        running = current

        val media = MediaItem.fromUri(Uri.fromFile(File(request.source)))
        // A passthrough carries no effect, so Transformer transmuxes.
        val item = if (request.passthrough) {
            EditedMediaItem.Builder(media).build()
        } else {
            val audio = mutableListOf<AudioProcessor>()
            if (request.audioChannels == 1) {
                audio += ChannelMixingAudioProcessor().apply {
                    for (input in 1..2) {
                        putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(input, 1))
                    }
                }
            }
            EditedMediaItem.Builder(media)
                .setEffects(
                    Effects(
                        audio,
                        listOf(
                            Presentation.createForWidthAndHeight(
                                request.width,
                                request.height,
                                Presentation.LAYOUT_SCALE_TO_FIT,
                            ),
                        ),
                    ),
                )
                .build()
        }
        transformer.start(item, request.output)
        poll(current)
    }

    private fun encodersFor(request: CompressionRequest) = DefaultEncoderFactory.Builder(context)
        .setRequestedVideoEncoderSettings(
            VideoEncoderSettings.Builder()
                .setBitrate(request.videoBitrate)
                .setiFrameIntervalSeconds(1f)
                .build(),
        )
        .setRequestedAudioEncoderSettings(
            AudioEncoderSettings.Builder().setBitrate(request.audioBitrate).build(),
        )
        .setEnableFallback(true)
        .build()

    // A streamable file reserves a fixed 400 KB at its head for the index,
    // more than a short clip weighs; the index goes at the end instead, which
    // a player reads with one range request.
    private fun muxerFor(request: CompressionRequest) =
        InAppMp4Muxer.Factory()
            .setVideoDurationUs(request.durationUs)
            .setAttemptStreamableOutputEnabled(false)

    private fun finish(current: Running, report: () -> Unit) {
        if (current.finished) return
        current.finished = true
        report()
        if (running === current) running = null
        startNext()
    }

    private fun done(request: CompressionRequest, result: ExportResult) {
        val file = File(request.output)
        val reencoded = result.videoConversionProcess != ExportResult.CONVERSION_PROCESS_TRANSMUXED
        emit(
            mapOf(
                "job" to request.job,
                "type" to "done",
                "path" to request.output,
                "size" to file.length(),
                "durationUs" to if (result.durationMs > 0) result.durationMs * 1000 else request.durationUs,
                "width" to request.width,
                "height" to request.height,
                // The muxer patches the media box size at the head once the
                // samples are written: the head of the file changes at the end.
                "headerRewritten" to true,
                "reencoded" to reencoded,
            ),
        )
    }

    private fun poll(current: Running) {
        val holder = ProgressHolder()
        val tick = object : Runnable {
            override fun run() {
                if (current.finished) return
                val state = current.transformer.getProgress(holder)
                val fraction = if (state == Transformer.PROGRESS_STATE_AVAILABLE) holder.progress / 100.0 else 0.0
                emit(
                    mapOf(
                        "job" to current.request.job,
                        "type" to "progress",
                        // The muxer pre-sizes the file and trims it at the end,
                        // so its length says nothing about the bytes written.
                        "bytes" to 0L,
                        "positionUs" to (current.request.durationUs * fraction).toLong(),
                        "fraction" to fraction,
                    ),
                )
                main.postDelayed(this, 100)
            }
        }
        main.postDelayed(tick, 100)
    }

    companion object {
        /** What the Dart `SourceVideo` reads: display size, duration, codec, video bitrate, audio. */
        fun probe(path: String): Map<String, Any?> {
            if (!File(path).canRead()) throw CaptureException.failed("cannot read $path")
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(path)
            } catch (error: Exception) {
                extractor.release()
                throw CaptureException.failed("not a video: $path (${error.message})")
            }
            try {
                var video: MediaFormat? = null
                var audio: MediaFormat? = null
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (video == null && mime.startsWith("video/")) video = format
                    if (audio == null && mime.startsWith("audio/")) audio = format
                }
                val format = video ?: throw CaptureException.failed("no video track: $path")
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(path)
                    val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        ?.toIntOrNull() ?: 0
                    val width = format.getInteger(MediaFormat.KEY_WIDTH)
                    val height = format.getInteger(MediaFormat.KEY_HEIGHT)
                    val quarterTurn = rotation % 180 != 0
                    val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        format.getLong(MediaFormat.KEY_DURATION)
                    } else {
                        (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            ?.toLongOrNull() ?: 0L) * 1000
                    }
                    val codec = when (format.getString(MediaFormat.KEY_MIME)) {
                        MimeTypes.VIDEO_H264 -> "h264"
                        MimeTypes.VIDEO_H265 -> "hevc"
                        else -> "other"
                    }
                    return mapOf(
                        "width" to if (quarterTurn) height else width,
                        "height" to if (quarterTurn) width else height,
                        "durationUs" to durationUs,
                        "codec" to codec,
                        "videoBitrate" to videoBitrate(format, audio, retriever),
                        "hasAudio" to (audio != null),
                    )
                } finally {
                    retriever.release()
                }
            } finally {
                extractor.release()
            }
        }

        // The track's own bitrate when the container states it; else the
        // file's minus the audio track's.
        private fun videoBitrate(video: MediaFormat, audio: MediaFormat?, retriever: MediaMetadataRetriever): Int? {
            if (video.containsKey(MediaFormat.KEY_BIT_RATE)) return video.getInteger(MediaFormat.KEY_BIT_RATE)
            val total = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
                ?: return null
            val audioBitrate = if (audio?.containsKey(MediaFormat.KEY_BIT_RATE) == true) {
                audio.getInteger(MediaFormat.KEY_BIT_RATE)
            } else {
                0
            }
            return (total - audioBitrate).takeIf { it > 0 }
        }
    }
}
