package dev.mpx.library

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The native half of the Android save adapter: `saveBegin`, `saveStep` and
 * `saveAbort` on the plugin's method channel (the Dart `android_save_wire`
 * library documents them).
 *
 * A begin creates the item's [PendingWrite] ([SavePlace] picks which) and
 * opens its source; each step copies up to [STEP_BYTES] on the saver's own
 * thread and answers the bytes written, the last one publishing the item.
 * Errors answer a short code ([SaveErrors]) and never their message's path.
 */
internal class NativeSaver(private val context: Context) : PluginRegistry.ActivityResultListener {
    private val resolver: ContentResolver = context.contentResolver
    private val main = Handler(Looper.getMainLooper())
    // One thread of its own: a long copy never holds up the library's
    // queries, and steps of one write run in order anyway.
    private val thread = Executors.newSingleThreadExecutor()
    private val writes = ConcurrentHashMap<Int, SaveCopy>()
    private val lastWrite = AtomicInteger()
    private var activity: ActivityPluginBinding? = null
    private var dialog: ((Uri?) -> Unit)? = null

    fun attach(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    fun detach() {
        activity?.removeActivityResultListener(this)
        activity = null
        // The dialog's answer can no longer come: as dismissed.
        dialog?.invoke(null)
        dialog = null
    }

    fun dispose() {
        detach()
        thread.execute { writes.values.forEach { it.abort() }; writes.clear() }
        thread.shutdown()
    }

    // --- Methods ---

    fun begin(args: Map<*, *>, result: MethodChannel.Result) {
        val start = try {
            SaveStart.of(args)
        } catch (error: Exception) {
            return fail(result, error)
        }
        val place = SavePlace.of(start)
        if (place is SavePlace.Document) return beginDocument(start, result)
        background(result) { open(start) { pendingIn(place, start) } }
    }

    fun step(write: Int, result: MethodChannel.Result) = background(result) {
        val copy = writes[write] ?: throw SaveError("failed")
        try {
            if (!copy.step(STEP_BYTES)) {
                return@background mapOf("written" to copy.written, "total" to copy.total)
            }
            val published = copy.publish()
            mapOf(
                "written" to copy.written,
                "total" to copy.written,
                "done" to true,
                "ref" to published.ref,
                "renamed" to published.renamed,
            )
        } finally {
            // A failed step has discarded its write; a done one is over.
            if (copy.ended) writes.remove(write)
        }
    }

    fun abort(write: Int, result: MethodChannel.Result) = background(result) {
        writes.remove(write)?.abort()
        null
    }

    // --- Begin ---

    /** Opens [start]'s source, then its target, and registers the copy. */
    private fun open(start: SaveStart, target: () -> PendingWrite): Int {
        val (source, total) = sourceOf(start)
        val pending = try {
            target()
        } catch (error: Throwable) {
            source.close()
            throw error
        }
        val onPublished = {
            // The host let the saver consume its file; nothing on Android
            // adopts a file in place, so a move is a copy and a delete.
            if (start.move) start.path?.let { File(it).delete() }
            Unit
        }
        val id = lastWrite.incrementAndGet()
        writes[id] = SaveCopy(source, total, pending, onPublished = onPublished)
        return id
    }

    private fun sourceOf(start: SaveStart): Pair<InputStream, Long?> {
        start.bytes?.let { return ByteArrayInputStream(it) to it.size.toLong() }
        val file = File(start.path ?: throw SaveError("sourceMissing"))
        return try {
            FileInputStream(file) to file.length()
        } catch (error: FileNotFoundException) {
            throw SaveError("sourceMissing")
        }
    }

    private fun pendingIn(place: SavePlace, start: SaveStart): PendingWrite = when (place) {
        is SavePlace.Row -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStoreRow(resolver, place, start)
        } else {
            throw SaveError("failed")
        }
        is SavePlace.PublicFile -> PublicFile(context, place, start)
        SavePlace.Document -> throw SaveError("failed")
    }

    private fun beginDocument(start: SaveStart, result: MethodChannel.Result) {
        val host: Activity = activity?.activity ?: return result.error("noActivity", "no activity", null)
        if (dialog != null) return result.error("failed", "a save dialog is already open", null)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(start.mime)
            .putExtra(Intent.EXTRA_TITLE, SafeNames.file(start.name))
        dialog = { uri ->
            dialog = null
            if (uri == null) {
                result.success(null)
            } else {
                background(result) { open(start) { Document(resolver, uri, start) } }
            }
        }
        try {
            host.startActivityForResult(intent, DOCUMENT_REQUEST)
        } catch (error: Exception) {
            dialog = null
            result.error("noActivity", "no document provider", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != DOCUMENT_REQUEST) return false
        dialog?.invoke(if (resultCode == Activity.RESULT_OK) data?.data else null)
        return true
    }

    // --- Threads ---

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        thread.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: Throwable) {
                main.post { fail(result, error) }
            }
        }
    }

    private fun fail(result: MethodChannel.Result, error: Throwable) {
        val code = SaveErrors.codeOf(error)
        // The message can hold a path: the code is all that crosses.
        result.error(code, code, null)
    }

    companion object {
        /** How much one `saveStep` copies: a cancel lands within this. */
        const val STEP_BYTES = 4 * 1024 * 1024
    }
}

private const val DOCUMENT_REQUEST = 0x6d76

// --- Targets ---

/**
 * API 29 and later: a MediaStore row inserted with `IS_PENDING = 1`, which
 * keeps it from other apps until it is published with `IS_PENDING = 0`.
 * The store renames a taken name itself; the name read back says whether.
 */
@RequiresApi(Build.VERSION_CODES.Q)
private class MediaStoreRow(
    private val resolver: ContentResolver,
    place: SavePlace.Row,
    start: SaveStart,
) : PendingWrite {
    private val name = SafeNames.file(start.name)
    private val uri: Uri
    override val output: OutputStream

    init {
        val collection = when (place.collection) {
            SavePlace.Collection.IMAGES -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            SavePlace.Collection.VIDEO -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            SavePlace.Collection.DOWNLOADS -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, start.mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, place.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            place.dateTaken?.let { put(MediaStore.MediaColumns.DATE_TAKEN, it) }
        }
        uri = resolver.insert(collection, values) ?: throw SaveError("insertFailed")
        output = try {
            resolver.openOutputStream(uri, "w") ?: throw SaveError("insertFailed")
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    override fun publish(): Published {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        resolver.update(uri, values, null, null)
        return Published(uri.toString(), renamed = displayName(resolver, uri)?.let { it != name } ?: false)
    }

    override fun discard() {
        resolver.delete(uri, null, null)
    }
}

/**
 * API 28 and below: a hidden file next to its final place, renamed into
 * place when complete (`name(1)` … `name(10)` when the name is taken) and
 * handed to the media scanner, whose content URI is the ref.
 */
private class PublicFile(
    private val context: Context,
    place: SavePlace.PublicFile,
    private val start: SaveStart,
) : PendingWrite {
    private val name = SafeNames.file(start.name)
    private val scan = place.scan

    @Suppress("DEPRECATION")
    private val directory = Environment.getExternalStoragePublicDirectory(place.directory).let { root ->
        place.folder?.let { File(root, it) } ?: root
    }
    private val partial = File(directory, ".mpx-pending-${System.nanoTime()}-$name")

    override val output = run {
        if (!directory.isDirectory && !directory.mkdirs()) throw SaveError("failed")
        FileOutputStream(partial)
    }

    override fun publish(): Published {
        val free = LegacyNames.free(name) { File(directory, it).exists() } ?: throw SaveError("nameTaken")
        val file = File(directory, free)
        if (!partial.renameTo(file)) throw SaveError("failed")
        start.createdAtMs?.let { file.setLastModified(it) }
        val ref = if (scan) scanned(file) else null
        return Published((ref ?: Uri.fromFile(file)).toString(), renamed = free != name)
    }

    override fun discard() {
        partial.delete()
    }

    /** The content URI the media scanner gives [file], waiting a while for it. */
    private fun scanned(file: File): Uri? {
        val done = CountDownLatch(1)
        var uri: Uri? = null
        MediaScannerConnection.scanFile(context, arrayOf(file.path), arrayOf(start.mime)) { _, scannedUri ->
            uri = scannedUri
            done.countDown()
        }
        done.await(SCAN_WAIT_SECONDS, TimeUnit.SECONDS)
        return uri
    }

    companion object {
        const val SCAN_WAIT_SECONDS = 10L
    }
}

/**
 * The document the create-document dialog made. It is visible as soon as
 * the dialog returns (the provider owns it); a discard deletes it. The
 * provider may have renamed it (`name (1)`); the name read back says so.
 */
private class Document(
    private val resolver: ContentResolver,
    private val uri: Uri,
    start: SaveStart,
) : PendingWrite {
    private val name = SafeNames.file(start.name)
    override val output = resolver.openOutputStream(uri, "w") ?: throw SaveError("failed")

    override fun publish(): Published =
        Published(uri.toString(), renamed = displayName(resolver, uri)?.let { it != name } ?: false)

    override fun discard() {
        try {
            DocumentsContract.deleteDocument(resolver, uri)
        } catch (error: Exception) {
            // A provider that cannot delete leaves an empty document; there
            // is nothing more to do from here.
            Log.w("mpx_library", "could not delete a cancelled save's document: ${error.javaClass.simpleName}")
        }
    }
}

private fun displayName(resolver: ContentResolver, uri: Uri): String? =
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    }
