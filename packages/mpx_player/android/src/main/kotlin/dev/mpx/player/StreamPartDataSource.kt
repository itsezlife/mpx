package dev.mpx.player

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.hls.HlsDataSourceFactory
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException

/**
 * Asks Dart for the parts of HLS streams: Dart owns the cache keys, the
 * fetch policy and the publications, so the loader thread waits for its
 * answer. Pigeon's Flutter API is called on the main thread; the loader
 * thread blocks until the answer comes or the load is cancelled (ExoPlayer
 * interrupts a cancelled loader's thread).
 */
internal class StreamParts(private val flutter: PlayerFlutterApi) {
    private val main = Handler(Looper.getMainLooper())

    /** The part at [url] of [streamId]; a whole resource when [whole]. */
    fun open(streamId: Long, url: String, whole: Boolean): NativeStreamPart {
        val answer = CompletableFuture<NativeStreamPart>()
        main.post {
            flutter.openStreamPart(streamId, url, whole) { result ->
                result.fold(
                    onSuccess = { part ->
                        // Nobody waits for it any more: give it back.
                        if (!answer.complete(part)) close(part.partId)
                    },
                    onFailure = { answer.completeExceptionally(it) },
                )
            }
        }
        try {
            return answer.get()
        } catch (interrupted: InterruptedException) {
            if (!answer.cancel(false)) {
                runCatching { answer.getNow(null) }.getOrNull()?.let { close(it.partId) }
            }
            Thread.currentThread().interrupt()
            throw InterruptedIOException("opening $url was cancelled")
        } catch (failed: ExecutionException) {
            throw IOException("opening $url failed", failed.cause)
        }
    }

    fun close(partId: Long) {
        main.post { flutter.closeStreamPart(partId) {} }
    }
}

/**
 * One part of an HLS stream, opened through Dart: a playlist (or another
 * small whole resource, such as a key) arrives as bytes; a segment or an
 * init section is read natively from the cache under the key Dart published
 * it at, blocking only on missing bytes.
 */
@UnstableApi
internal class StreamPartDataSource(
    private val parts: StreamParts,
    private val streamId: Long,
    private val api: Long,
    private val readers: OpenReaders,
    private val whole: Boolean,
    private val traceId: Long,
) : DataSource {
    private val listeners = ArrayList<TransferListener>()
    private var delegate: DataSource? = null
    private var partId: Long? = null

    override fun addTransferListener(transferListener: TransferListener) {
        listeners.add(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val part =
            MpxPlayerTrace.section("part-open", traceId, if (whole) "whole" else "media") {
                parts.open(streamId, dataSpec.uri.toString(), whole)
            }
        partId = part.partId
        val bytes = part.bytes
        val key = part.cacheKey
        val source: DataSource =
            when {
                bytes != null -> ByteArrayDataSource(bytes)
                key != null -> HbcDataSource(api, key, readers, traceId)
                else -> throw IOException("${dataSpec.uri} came back empty")
            }
        listeners.forEach(source::addTransferListener)
        delegate = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        delegate?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT

    override fun getUri(): Uri? = delegate?.uri

    override fun getResponseHeaders(): Map<String, List<String>> =
        delegate?.responseHeaders ?: emptyMap()

    override fun close() {
        try {
            delegate?.close()
        } finally {
            delegate = null
            partId?.let(parts::close)
            partId = null
        }
    }

    /**
     * Data sources of one player's stream: media segments and init sections
     * are read natively, every other part (playlists, keys) whole.
     */
    class Factory(
        private val parts: StreamParts,
        private val streamId: Long,
        private val api: Long,
        private val readers: OpenReaders,
        private val traceId: Long,
    ) : HlsDataSourceFactory {
        override fun createDataSource(dataType: Int): DataSource =
            StreamPartDataSource(
                parts,
                streamId,
                api,
                readers,
                whole =
                    dataType != C.DATA_TYPE_MEDIA &&
                        dataType != C.DATA_TYPE_MEDIA_INITIALIZATION,
                traceId = traceId,
            )
    }
}
