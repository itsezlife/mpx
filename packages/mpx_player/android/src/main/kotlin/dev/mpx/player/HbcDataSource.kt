package dev.mpx.player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import java.io.IOException
import java.io.InterruptedIOException

/**
 * The readers one player has open, so a seek or a release can wake the reads
 * blocked on missing bytes.
 *
 * Cancelling and closing go under one lock: the reader's contract forbids a
 * call on a reader that is being closed. Cancelling is not sticky, so a read
 * that blocks right after is woken only by its bytes landing (which the cache
 * fetches anyway).
 */
internal class OpenReaders(private val api: Long) {
    private val readers = HashSet<Long>()

    fun add(reader: Long) = synchronized(this) { readers.add(reader) }

    fun close(reader: Long) =
        synchronized(this) {
            readers.remove(reader)
            HbcNative.close(api, reader)
        }

    fun cancelAll() = synchronized(this) { readers.forEach { HbcNative.cancel(api, it) } }
}

/**
 * A data source over one published ranged resource: reads go straight to the
 * cached sparse file and block, on the loader's thread, only while bytes are
 * missing (the cache fetches them meanwhile).
 *
 * Each open, and the first read after it, is a section of the player
 * [traceId]'s marks in the system trace ([MpxPlayerTrace]).
 */
@UnstableApi
internal class HbcDataSource(
    private val api: Long,
    private val key: String,
    private val readers: OpenReaders,
    private val traceId: Long,
) : BaseDataSource(/* isNetwork= */ false) {
    private var reader = 0L
    private var uri: Uri? = null
    private var position = 0L
    private var remaining = 0L
    private var opened = false
    private var firstRead = false

    override fun open(dataSpec: DataSpec): Long =
        MpxPlayerTrace.section("source-open", traceId, "at=${dataSpec.position}") {
            openTraced(dataSpec)
        }

    private fun openTraced(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val opening = HbcNative.open(api, key)
        if (opening == 0L) {
            throw DataSourceException(
                IOException("$key is not published to the native reader"),
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
            )
        }
        reader = opening
        readers.add(opening)
        uri = dataSpec.uri
        val length = HbcNative.length(api, opening, true)
        if (length < 0) throw failure(length)
        if (dataSpec.position > length) {
            throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        }
        position = dataSpec.position
        val available = length - position
        remaining =
            if (dataSpec.length == C.LENGTH_UNSET.toLong()) available
            else minOf(dataSpec.length, available)
        opened = true
        firstRead = true
        transferStarted(dataSpec)
        return remaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (!firstRead) return readTraced(buffer, offset, length)
        firstRead = false
        return MpxPlayerTrace.section("source-first-read", traceId, "at=$position") {
            readTraced(buffer, offset, length)
        }
    }

    private fun readTraced(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val wanted = minOf(length.toLong(), remaining).toInt()
        val read = HbcNative.read(api, reader, position, buffer, offset, wanted)
        if (read == 0L) return C.RESULT_END_OF_INPUT
        if (read < 0) throw failure(read)
        position += read
        remaining -= read
        bytesTransferred(read.toInt())
        return read.toInt()
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        uri = null
        if (reader != 0L) {
            readers.close(reader)
            reader = 0L
        }
        if (opened) {
            opened = false
            transferEnded()
        }
    }

    private fun failure(code: Long): IOException =
        when (code) {
            // A seek or a release woke the read: the loader is being
            // cancelled, as an interrupted network read would be.
            HbcNative.ERR_CANCELLED -> InterruptedIOException("read of $key cancelled")
            HbcNative.ERR_FAILED ->
                DataSourceException(
                    IOException("fetch of $key failed"),
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                )
            HbcNative.ERR_CLOSED ->
                DataSourceException(
                    IOException("$key was unpublished"),
                    PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                )
            else ->
                DataSourceException(
                    IOException("read of $key failed ($code)"),
                    PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                )
        }

    class Factory(
        private val api: Long,
        private val key: String,
        private val readers: OpenReaders,
        private val traceId: Long,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource = HbcDataSource(api, key, readers, traceId)
    }
}
