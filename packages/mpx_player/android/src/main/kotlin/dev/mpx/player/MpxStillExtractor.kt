package dev.mpx.player

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The platform's still extractor ([PlayerStillHostApi]): the first frame of a
 * video drawn by the platform's metadata retriever, which uses the device's
 * decoders (hardware ones included), for codecs the software decoder was built
 * without.
 *
 * A ranged resource is read through the bytes cache's native reader by a
 * [MediaDataSource]; reads block on bytes still downloading, so extraction
 * runs on a thread of its own, one still at a time. A cancel wakes the
 * blocked reads; the retriever then fails and the request answers null.
 */
internal class MpxStillExtractor : PlayerStillHostApi {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "mpx-still").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private val running = ConcurrentHashMap<Long, OpenReaders>()
    private val cancelled = ConcurrentHashMap.newKeySet<Long>()

    override fun extractStill(request: NativeStillRequest, callback: (Result<NativeStill?>) -> Unit) {
        executor.execute {
            val result =
                try {
                    Result.success(extract(request))
                } catch (error: Throwable) {
                    // A source the retriever cannot read, or reads woken by a
                    // cancel: the platform draws no frame.
                    Result.success(null)
                } finally {
                    running.remove(request.requestId)
                    cancelled.remove(request.requestId)
                }
            main.post { callback(result) }
        }
    }

    override fun cancelStill(requestId: Long) {
        cancelled.add(requestId)
        running[requestId]?.cancelAll()
    }

    /** Stops taking requests; the one running ends with its reads. */
    fun dispose() {
        running.values.forEach { it.cancelAll() }
        executor.shutdown()
    }

    private fun extract(request: NativeStillRequest): NativeStill? {
        if (cancelled.contains(request.requestId)) return null
        val retriever = MediaMetadataRetriever()
        var source: HbcMediaDataSource? = null
        try {
            val path = request.path
            val key = request.cacheKey
            val api = request.readerApi
            when {
                path != null -> retriever.setDataSource(path)
                key != null && api != null -> {
                    // Later versions only append to the table: an older one
                    // is refused rather than misread.
                    if (HbcNative.version(api) < HbcNative.expectedVersion()) return null
                    val readers = OpenReaders(api)
                    running[request.requestId] = readers
                    if (cancelled.contains(request.requestId)) return null
                    source = HbcMediaDataSource(api, key, readers)
                    retriever.setDataSource(source)
                }
                else -> return null
            }
            val maxWidth = max(1, request.maxWidth.toInt())
            val maxHeight = max(1, request.maxHeight.toInt())
            val frame =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        0,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxWidth,
                        maxHeight,
                    )
                } else {
                    retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } ?: return null
            return toStill(fitted(frame, maxWidth, maxHeight))
        } finally {
            retriever.release()
            source?.close()
        }
    }

    // Scales [frame] down into the box, aspect kept; never up.
    private fun fitted(frame: Bitmap, maxWidth: Int, maxHeight: Int): Bitmap {
        val scale = min(1.0, min(maxWidth.toDouble() / frame.width, maxHeight.toDouble() / frame.height))
        if (scale >= 1.0) return frame
        val width = max(1, (frame.width * scale).roundToInt())
        val height = max(1, (frame.height * scale).roundToInt())
        val scaled = Bitmap.createScaledBitmap(frame, width, height, true)
        if (scaled !== frame) frame.recycle()
        return scaled
    }

    // ARGB_8888 is laid out as RGBA bytes in memory, premultiplied.
    private fun toStill(frame: Bitmap): NativeStill {
        val rgba =
            if (frame.config == Bitmap.Config.ARGB_8888) frame
            else frame.copy(Bitmap.Config.ARGB_8888, false).also { frame.recycle() }
        try {
            val buffer = ByteBuffer.allocate(rgba.byteCount)
            rgba.copyPixelsToBuffer(buffer)
            val packed = packed(buffer.array(), rgba.width, rgba.height, rgba.rowBytes)
            return NativeStill(rgba.width.toLong(), rgba.height.toLong(), packed)
        } finally {
            rgba.recycle()
        }
    }

    // Drops the padding a bitmap's rows may carry.
    private fun packed(bytes: ByteArray, width: Int, height: Int, rowBytes: Int): ByteArray {
        val row = width * 4
        if (rowBytes == row) return bytes
        val out = ByteArray(row * height)
        for (y in 0 until height) System.arraycopy(bytes, y * rowBytes, out, y * row, row)
        return out
    }
}

/**
 * The retriever's data source over one published ranged resource: reads go
 * to the cached sparse file and block, on the extractor's thread, only while
 * bytes are missing.
 */
private class HbcMediaDataSource(
    private val api: Long,
    private val key: String,
    private val readers: OpenReaders,
) : MediaDataSource() {
    private val reader: Long = HbcNative.open(api, key)

    init {
        if (reader == 0L) throw IOException("$key is not published to the native reader")
        readers.add(reader)
    }

    private var closed = false

    override fun getSize(): Long {
        val length = HbcNative.length(api, reader, true)
        return if (length < 0) -1 else length
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size == 0) return 0
        val read = HbcNative.read(api, reader, position, buffer, offset, size)
        if (read == 0L) return -1
        if (read < 0) throw IOException("read of $key failed ($read)")
        return read.toInt()
    }

    override fun close() {
        if (closed) return
        closed = true
        readers.close(reader)
    }
}
