package dev.mpx.player

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
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
 * runs on threads of its own, a few stills at a time. A cancel wakes the
 * blocked reads; the retriever then fails and the request answers null. A
 * request that runs past its deadline is cancelled the same way, so bytes
 * that never arrive hold one thread for a while, not the extractor for good.
 *
 * Every call is answered exactly once: a request still queued or running at
 * [dispose], and a call after it, answer null.
 */
internal class MpxStillExtractor : PlayerStillHostApi {
    private val executor: ExecutorService = Executors.newFixedThreadPool(WORKERS) { runnable ->
        Thread(runnable, "mpx-still").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    // Every request from its call until its answer, by id. A cancel of an id
    // not here (finished, or never asked) is a no-op, so nothing outlives it.
    private val pending = HashMap<Long, Request>()
    private var disposed = false

    private class Request(val callback: (Result<NativeStill?>) -> Unit) {
        @Volatile var cancelled = false

        // The readers of its ranged resource, once open; under [lock].
        var readers: OpenReaders? = null
    }

    override fun extractStill(request: NativeStillRequest, callback: (Result<NativeStill?>) -> Unit) {
        val id = request.requestId
        val job = Request(callback)
        val taken =
            synchronized(lock) {
                if (disposed || pending.containsKey(id)) {
                    false
                } else {
                    pending[id] = job
                    true
                }
            }
        if (!taken) {
            main.post { callback(Result.success(null)) }
            return
        }
        try {
            executor.execute { perform(request, job) }
        } catch (error: RejectedExecutionException) {
            answer(id, null)
        }
    }

    override fun cancelStill(requestId: Long) = wake(requestId)

    /**
     * Stops taking requests: the ones queued or running answer null now, the
     * running ones' reads are woken, and later calls answer null.
     */
    fun dispose() {
        val ids =
            synchronized(lock) {
                disposed = true
                pending.keys.toList()
            }
        executor.shutdownNow()
        for (id in ids) {
            wake(id)
            answer(id, null)
        }
    }

    private fun perform(request: NativeStillRequest, job: Request) {
        val id = request.requestId
        val deadline = Runnable { wake(id) }
        main.postDelayed(deadline, DEADLINE_MS)
        val still =
            try {
                extract(request, job)
            } catch (error: Throwable) {
                // A source the retriever cannot read, or reads woken by a
                // cancel: the platform draws no frame.
                null
            } finally {
                main.removeCallbacks(deadline)
            }
        answer(id, still)
    }

    // Answers request [id] once; later answers (a dispose raced a finish)
    // find it gone.
    private fun answer(id: Long, still: NativeStill?) {
        val job = synchronized(lock) { pending.remove(id) } ?: return
        main.post { job.callback(Result.success(still)) }
    }

    // Cancels request [id] while it is pending. A native cancel wakes only
    // the reads blocked at that moment, so a running one is woken again until
    // it answers.
    private fun wake(id: Long) {
        val readers =
            synchronized(lock) {
                val job = pending[id] ?: return
                job.cancelled = true
                job.readers
            } ?: return
        readers.cancelAll()
        main.postDelayed({ wake(id) }, REWAKE_MS)
    }

    private fun extract(request: NativeStillRequest, job: Request): NativeStill? {
        if (job.cancelled) return null
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
                    synchronized(lock) { job.readers = readers }
                    if (job.cancelled) return null
                    source = HbcMediaDataSource(api, key, readers) { job.cancelled }
                    // A cancel that came while the reader opened found none
                    // to wake.
                    if (job.cancelled) return null
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

    private companion object {
        // Stills drawn at once: a blocked one leaves the others a thread.
        const val WORKERS = 2

        // How long a still may take before its reads are cancelled.
        const val DEADLINE_MS = 20_000L

        // How often a cancelled request's reads are woken until it answers.
        const val REWAKE_MS = 1_000L
    }
}

/**
 * The retriever's data source over one published ranged resource: reads go
 * to the cached sparse file and block, on the extractor's thread, only while
 * bytes are missing. Once [cancelled] holds, every read fails at once: a
 * native cancel wakes only the reads blocked at that moment.
 */
private class HbcMediaDataSource(
    private val api: Long,
    private val key: String,
    private val readers: OpenReaders,
    private val cancelled: () -> Boolean,
) : MediaDataSource() {
    private val reader: Long = HbcNative.open(api, key)

    init {
        if (reader == 0L) throw IOException("$key is not published to the native reader")
        readers.add(reader)
    }

    private var closed = false

    override fun getSize(): Long {
        if (cancelled()) throw IOException("read of $key cancelled")
        val length = HbcNative.length(api, reader, true)
        return if (length < 0) -1 else length
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size == 0) return 0
        if (cancelled()) throw IOException("read of $key cancelled")
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
