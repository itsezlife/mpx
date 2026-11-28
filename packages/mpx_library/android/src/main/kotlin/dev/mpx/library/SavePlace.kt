package dev.mpx.library

import android.os.Build

/**
 * One item the Dart side asks the native saver to begin (`saveBegin`; the
 * Dart `AndroidSaveStartCodec` is the wire). Exactly one of [path] and
 * [bytes] is set.
 */
internal data class SaveStart(
    val destination: String,
    val folder: String?,
    val name: String,
    val mime: String,
    val kind: String,
    val createdAtMs: Long?,
    val path: String?,
    val bytes: ByteArray?,
    val move: Boolean,
) {
    companion object {
        fun of(args: Map<*, *>): SaveStart = SaveStart(
            destination = args["destination"] as? String ?: throw SaveError("failed"),
            folder = args["folder"] as? String,
            name = args["name"] as? String ?: throw SaveError("failed"),
            mime = args["mime"] as? String ?: throw SaveError("failed"),
            kind = args["kind"] as? String ?: throw SaveError("failed"),
            createdAtMs = (args["createdAtMs"] as? Number)?.toLong(),
            path = args["path"] as? String,
            bytes = args["bytes"] as? ByteArray,
            move = args["move"] == true,
        )
    }
}

/**
 * Where one item goes on this device, decided from its [SaveStart] and the
 * API level alone, so it is tested on the JVM.
 */
internal sealed interface SavePlace {
    enum class Collection { IMAGES, VIDEO, DOWNLOADS }

    /**
     * API 29 and later: a MediaStore row in [collection] under
     * [relativePath], inserted pending; [dateTaken] is written for images and
     * video only (the downloads collection keeps none).
     */
    data class Row(val collection: Collection, val relativePath: String, val dateTaken: Long?) : SavePlace

    /**
     * API 28 and below: a file in the public [directory] (in [folder] when
     * set), handed to the media scanner when [scan].
     */
    data class PublicFile(val directory: String, val folder: String?, val scan: Boolean) : SavePlace

    /** The system's create-document dialog. */
    object Document : SavePlace

    companion object {
        // The values of `Environment.DIRECTORY_PICTURES`, `_MOVIES` and
        // `_DOWNLOADS`, spelled out: the JVM test host's android.jar has no
        // constant values, and the names are fixed platform API.
        const val PICTURES = "Pictures"
        const val MOVIES = "Movies"
        const val DOWNLOADS = "Download"

        fun of(start: SaveStart, sdk: Int = Build.VERSION.SDK_INT): SavePlace {
            if (start.destination == "ask") return Document
            val folder = start.folder?.let(SafeNames::folder)
            val collection = when {
                start.destination == "downloads" -> Collection.DOWNLOADS
                start.kind == "photo" -> Collection.IMAGES
                start.kind == "video" -> Collection.VIDEO
                // An animation (and a file the Dart side routed) goes by its
                // MIME type: a GIF to the images, an mp4 to the video.
                start.mime.startsWith("image/", ignoreCase = true) -> Collection.IMAGES
                else -> Collection.VIDEO
            }
            val directory = when (collection) {
                Collection.IMAGES -> PICTURES
                Collection.VIDEO -> MOVIES
                Collection.DOWNLOADS -> DOWNLOADS
            }
            if (sdk < Build.VERSION_CODES.Q) return PublicFile(directory, folder, scan = true)
            return Row(
                collection,
                if (folder == null) directory else "$directory/$folder",
                dateTaken = start.createdAtMs.takeIf { collection != Collection.DOWNLOADS },
            )
        }
    }
}

/** Names from the host made safe to use as one path segment. */
internal object SafeNames {
    /** [name] as one segment; null when nothing usable is left. */
    fun folder(name: String): String? {
        val safe = name.replace('/', '_').replace('\\', '_').trim()
        return safe.takeUnless { it.isEmpty() || it == "." || it == ".." }
    }

    /** [name] as a file name; `file` when nothing usable is left. */
    fun file(name: String): String = folder(name) ?: "file"
}

/**
 * The collision rule below API 29, where the saver writes the file itself:
 * a taken `name.ext` becomes `name(1).ext`, up to `name(10).ext`.
 */
internal object LegacyNames {
    const val LIMIT = 10

    /** The first of [name], `name(1)` … `name(10)` not [taken]; null when all are. */
    fun free(name: String, taken: (String) -> Boolean): String? {
        if (!taken(name)) return name
        val dot = name.lastIndexOf('.')
        val (base, extension) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        return (1..LIMIT).map { "$base($it)$extension" }.firstOrNull { !taken(it) }
    }
}

/** A failure the saver names itself, by its wire [code]. */
internal class SaveError(val code: String) : Exception(code)

/**
 * A throwable as the short code the Dart side maps to a reason: `ENOSPC`,
 * `security`, `mimeRejected`, a [SaveError]'s own code, else `failed`. The
 * message never crosses: it can hold a path or a URI.
 */
internal object SaveErrors {
    fun codeOf(error: Throwable): String {
        if (error is SaveError) return error.code
        if (generateSequence(error) { it.cause }.any { cause ->
                val message = cause.message ?: ""
                message.contains("ENOSPC") || message.contains("No space left", ignoreCase = true)
            }
        ) {
            return "ENOSPC"
        }
        return when (error) {
            is SecurityException -> "security"
            // MediaStore refuses a MIME type its collection does not take
            // with an IllegalArgumentException on insert.
            is IllegalArgumentException -> "mimeRejected"
            else -> "failed"
        }
    }
}
