package dev.mpx.library

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.provider.MediaStore
import android.util.Size
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * The device library over MediaStore (the Dart `PlatformMediaLibrary`, the
 * wire of `LibraryWire`): images and videos of the Files table merged, newest
 * first by modified date (taken date on API 28 and below). Every query blocks;
 * the plugin runs them off the main thread.
 *
 * Album ids: `all`, `photos`, `videos`, and `bucket:<id>` for a folder (the
 * camera folder's kind is `camera`).
 */
class MediaStoreLibrary(private val context: Context) {
    private val resolver: ContentResolver get() = context.contentResolver
    private val files: Uri = MediaStore.Files.getContentUri("external")
    private val prefs = context.getSharedPreferences("dev.mpx.library", Context.MODE_PRIVATE)

    // --- Access ---

    var asked: Boolean
        get() = prefs.getBoolean("asked", false)
        set(value) = prefs.edit().putBoolean("asked", value).apply()

    /** The permissions a request asks for on this API level. */
    fun permissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun access(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "sdk" to Build.VERSION.SDK_INT,
        "images" to (Build.VERSION.SDK_INT >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES)),
        "video" to (Build.VERSION.SDK_INT >= 33 && granted(Manifest.permission.READ_MEDIA_VIDEO)),
        "selected" to (Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)),
        "legacy" to (Build.VERSION.SDK_INT < 33 && granted(Manifest.permission.READ_EXTERNAL_STORAGE)),
        "asked" to asked,
    )

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // --- Albums ---

    private val mediaSelection =
        "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (" +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"

    private val dateColumn =
        if (Build.VERSION.SDK_INT > 28) MediaStore.MediaColumns.DATE_MODIFIED else "datetaken"

    private val columns = arrayOf(
        MediaStore.MediaColumns._ID,
        MediaStore.Files.FileColumns.MEDIA_TYPE,
        MediaStore.MediaColumns.MIME_TYPE,
        MediaStore.MediaColumns.SIZE,
        MediaStore.MediaColumns.WIDTH,
        MediaStore.MediaColumns.HEIGHT,
        "duration",
        "orientation",
        "datetaken",
        MediaStore.MediaColumns.DATE_MODIFIED,
        "bucket_id",
        "bucket_display_name",
    )

    /**
     * One pass over the library, newest first, counting per folder: the
     * all-media album, all photos, all videos, the camera folder, then the
     * other folders by their newest item. Only one row per album is kept.
     */
    fun albums(): List<Map<String, Any?>> {
        var all = 0
        var photos = 0
        var videos = 0
        var allCover: Map<String, Any?>? = null
        var photoCover: Map<String, Any?>? = null
        var videoCover: Map<String, Any?>? = null
        val buckets = LinkedHashMap<String, MutableMap<String, Any?>>()
        query(mediaSelection, emptyArray(), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val asset by lazy { assetOf(cursor) }
                all++
                if (allCover == null) allCover = asset
                if (isVideo(cursor)) {
                    videos++
                    if (videoCover == null) videoCover = asset
                } else {
                    photos++
                    if (photoCover == null) photoCover = asset
                }
                val bucket = cursor.string("bucket_id") ?: continue
                val entry = buckets.getOrPut(bucket) {
                    val name = cursor.string("bucket_display_name") ?: ""
                    mutableMapOf(
                        "id" to "bucket:$bucket",
                        "kind" to if (name.equals("Camera", ignoreCase = true)) "camera" else "system",
                        "title" to name,
                        "count" to 0,
                        "cover" to asset,
                    )
                }
                entry["count"] = (entry["count"] as Int) + 1
            }
        }
        val result = mutableListOf<Map<String, Any?>>(
            mapOf("id" to "all", "kind" to "allMedia", "title" to "", "count" to all, "cover" to allCover),
        )
        if (photos > 0) result += mapOf("id" to "photos", "kind" to "allPhotos", "title" to "", "count" to photos, "cover" to photoCover)
        if (videos > 0) result += mapOf("id" to "videos", "kind" to "allVideos", "title" to "", "count" to videos, "cover" to videoCover)
        val (camera, others) = buckets.values.partition { it["kind"] == "camera" }
        result += camera
        result += others
        return result
    }

    // --- Pages ---

    fun page(album: String, offset: Int, limit: Int): Map<String, Any?> {
        val (selection, args) = selectionOf(album)
        val total = count(selection, args)
        val assets = mutableListOf<Map<String, Any?>>()
        if (offset < total) {
            query(selection, args, offset to limit)?.use { cursor ->
                while (cursor.moveToNext() && assets.size < limit) assets += assetOf(cursor)
            }
        }
        return mapOf("total" to total, "assets" to assets)
    }

    private fun selectionOf(album: String): Pair<String, Array<String>> = when {
        album == "all" -> mediaSelection to emptyArray()
        album == "photos" ->
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}" to emptyArray()
        album == "videos" ->
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO}" to emptyArray()
        album.startsWith("bucket:") -> "$mediaSelection AND bucket_id = ?" to arrayOf(album.removePrefix("bucket:"))
        else -> "0" to emptyArray()
    }

    private fun count(selection: String, args: Array<String>): Int =
        resolver.query(files, arrayOf(MediaStore.MediaColumns._ID), selection, args, null)
            ?.use { it.count } ?: 0

    private fun query(selection: String, args: Array<String>, window: Pair<Int, Int>?): Cursor? {
        val order = "$dateColumn DESC, ${MediaStore.MediaColumns._ID} DESC"
        if (Build.VERSION.SDK_INT >= 30) {
            val bundle = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, order)
                if (window != null) {
                    putInt(ContentResolver.QUERY_ARG_OFFSET, window.first)
                    putInt(ContentResolver.QUERY_ARG_LIMIT, window.second)
                }
            }
            return resolver.query(files, columns, bundle, null)
        }
        val limited = if (window == null) order else "$order LIMIT ${window.second} OFFSET ${window.first}"
        return resolver.query(files, columns, selection, args, limited)
    }

    private fun isVideo(cursor: Cursor) =
        cursor.int(MediaStore.Files.FileColumns.MEDIA_TYPE) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO

    private fun assetOf(cursor: Cursor): Map<String, Any?> {
        val video = isVideo(cursor)
        val orientation = cursor.int("orientation")
        val turned = orientation == 90 || orientation == 270
        val width = cursor.int(MediaStore.MediaColumns.WIDTH)
        val height = cursor.int(MediaStore.MediaColumns.HEIGHT)
        val mime = cursor.string(MediaStore.MediaColumns.MIME_TYPE)
        return mapOf(
            "id" to cursor.long(MediaStore.MediaColumns._ID).toString(),
            "kind" to if (video) "video" else "photo",
            "subtypes" to if (mime == "image/gif") listOf("animated") else emptyList(),
            "width" to if (turned) height else width,
            "height" to if (turned) width else height,
            "durationMs" to if (video) cursor.long("duration") else null,
            "createdMs" to cursor.long("datetaken").takeIf { it > 0 },
            "modifiedMs" to cursor.long(MediaStore.MediaColumns.DATE_MODIFIED) * 1000,
            "mime" to mime,
            "size" to cursor.long(MediaStore.MediaColumns.SIZE),
            "cloud" to false,
        )
    }

    // --- Reads ---

    /** The content URI of asset [id], or null when it is gone. */
    fun uriOf(id: String): Uri? {
        val rowId = id.toLongOrNull() ?: return null
        val type = resolver.query(
            files,
            arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE),
            "${MediaStore.MediaColumns._ID} = ?",
            arrayOf(id),
            null,
        )?.use { if (it.moveToFirst()) it.getInt(0) else null } ?: return null
        val base = if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        return ContentUris.withAppendedId(base, rowId)
    }

    fun thumbnail(id: String, pixels: Int, cancel: CancellationSignal): ByteArray {
        val uri = uriOf(id) ?: throw LibraryError("unavailable", "no asset $id")
        val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= 29) {
            resolver.loadThumbnail(uri, Size(pixels, pixels), cancel)
        } else {
            legacyThumbnail(uri, id)
        } ?: throw LibraryError("unavailable", "no thumbnail for $id")
        val scaled = fit(bitmap, pixels)
        try {
            return ByteArrayOutputStream().also {
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, it)
            }.toByteArray()
        } finally {
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyThumbnail(uri: Uri, id: String): Bitmap? {
        val rowId = id.toLong()
        return if (uri.toString().startsWith(MediaStore.Video.Media.EXTERNAL_CONTENT_URI.toString())) {
            MediaStore.Video.Thumbnails.getThumbnail(resolver, rowId, MediaStore.Video.Thumbnails.MINI_KIND, null)
        } else {
            MediaStore.Images.Thumbnails.getThumbnail(resolver, rowId, MediaStore.Images.Thumbnails.MINI_KIND, null)
        }
    }

    private fun fit(bitmap: Bitmap, pixels: Int): Bitmap {
        val longSide = maxOf(bitmap.width, bitmap.height)
        if (longSide <= pixels) return bitmap
        val scale = pixels.toFloat() / longSide
        return Bitmap.createScaledBitmap(
            bitmap,
            maxOf(1, (bitmap.width * scale).toInt()),
            maxOf(1, (bitmap.height * scale).toInt()),
            true,
        )
    }

    /** The ones of [ids] that are still rows of the library. */
    fun present(ids: List<String>): List<String> {
        val rows = ids.mapNotNull { it.toLongOrNull() }
        if (rows.isEmpty()) return emptyList()
        val found = mutableListOf<String>()
        for (chunk in rows.chunked(500)) {
            val marks = chunk.joinToString(",") { "?" }
            resolver.query(
                files,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns._ID} IN ($marks)",
                chunk.map { it.toString() }.toTypedArray(),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) found.add(cursor.getLong(0).toString())
            }
        }
        return found
    }

    /**
     * The content URI of video [id], which a player opens in place (no copy,
     * unlike [original]); null for a photo or a row that is gone.
     */
    fun playable(id: String): String? {
        val uri = uriOf(id) ?: return null
        val mime = resolver.getType(uri) ?: return null
        return if (mime.startsWith("video/")) uri.toString() else null
    }

    /**
     * Copies asset [id]'s original into the plugin's cache folder (a content
     * URI is no path), reporting the bytes as they copy only when
     * [onProgress] is set; the lease is the copy, deleted on release.
     */
    fun original(id: String, cancel: CancellationSignal): Map<String, Any?> {
        val uri = uriOf(id) ?: throw LibraryError("unavailable", "no asset $id")
        val mime = resolver.getType(uri)
        val extension = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"
        val folder = File(context.cacheDir, "mpx_library/originals").apply { mkdirs() }
        val file = File(folder, "$id-${System.nanoTime()}.$extension")
        try {
            val input = resolver.openInputStream(uri) ?: throw LibraryError("unavailable", "cannot open $id")
            input.use { source ->
                file.outputStream().use { sink ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        if (cancel.isCanceled) throw LibraryError("unavailable", "cancelled")
                        val read = source.read(buffer)
                        if (read < 0) break
                        sink.write(buffer, 0, read)
                    }
                }
            }
        } catch (error: Exception) {
            file.delete()
            throw error as? LibraryError ?: LibraryError("unavailable", error.message ?: "$error")
        }
        return mapOf("path" to file.path, "mime" to mime)
    }

    fun release(path: String) {
        val folder = File(context.cacheDir, "mpx_library/originals")
        val file = File(path)
        if (file.parentFile?.canonicalPath == folder.canonicalPath) file.delete()
    }

    private fun Cursor.index(column: String) = getColumnIndex(column)
    private fun Cursor.string(column: String): String? = index(column).let { if (it < 0 || isNull(it)) null else getString(it) }
    private fun Cursor.int(column: String): Int = index(column).let { if (it < 0 || isNull(it)) 0 else getInt(it) }
    private fun Cursor.long(column: String): Long = index(column).let { if (it < 0 || isNull(it)) 0 else getLong(it) }
}

/** An error that crosses the channel; [code] picks the Dart exception. */
class LibraryError(val code: String, override val message: String) : Exception(message)
