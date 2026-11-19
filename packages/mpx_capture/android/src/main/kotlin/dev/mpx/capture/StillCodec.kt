package dev.mpx.capture

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.drawable.AnimatedImageDrawable
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import kotlin.math.max

/**
 * The still and poster work of media preparation (the Dart
 * `PlatformPreparationCodec`): read a still's facts, encode a JPEG from a
 * downsampled decode, and draw a video's first frame. Sizes are as
 * displayed: the EXIF orientation is applied. Android writes baseline JPEGs
 * only; the `progressive` flag is ignored. Every call blocks; the plugin runs
 * them on its preparation threads.
 */
object StillCodec {
    fun probe(path: String): Map<String, Any?> {
        val file = File(path)
        val bounds = bounds(path)
        val orientation = orientation(path)
        val turned = quarterTurned(orientation)
        return mapOf(
            "width" to if (turned) bounds.outHeight else bounds.outWidth,
            "height" to if (turned) bounds.outWidth else bounds.outHeight,
            "size" to file.length(),
            "mime" to bounds.outMimeType,
            "animated" to isAnimated(file, bounds.outMimeType),
        )
    }

    fun encode(
        path: String,
        maxSide: Int,
        quality: Int,
        output: String?,
    ): Map<String, Any?> {
        val bounds = bounds(path)
        val orientation = orientation(path)
        val longSide = max(bounds.outWidth, bounds.outHeight)
        val targetLong = minOf(maxSide, longSide)
        // The largest power-of-two step that still decodes at least the
        // target: the decoder skips pixels instead of holding the whole
        // picture, and the exact scale below finishes the job.
        var sample = 1
        while (longSide / (sample * 2) >= targetLong) sample *= 2
        val decoded = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw CaptureException.failed("cannot decode $path")
        val upright = transformed(decoded, orientation, targetLong)
        val flat = flattened(upright)
        try {
            return write(flat, quality, output)
        } finally {
            flat.recycle()
        }
    }

    fun videoThumbnail(path: String, maxSide: Int, quality: Int): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        val frame = try {
            retriever.setDataSource(path)
            retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (error: Exception) {
            null
        } finally {
            retriever.release()
        } ?: throw CaptureException.failed("not a video: $path")
        val scaled = transformed(frame, ExifInterface.ORIENTATION_NORMAL, maxSide)
        try {
            return write(scaled, quality, null)
        } finally {
            scaled.recycle()
        }
    }

    // --- Helpers ---

    private fun bounds(path: String): BitmapFactory.Options {
        if (!File(path).isFile) throw CaptureException.failed("not a still: $path")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw CaptureException.failed("not a still: $path")
        }
        return bounds
    }

    private fun orientation(path: String): Int = try {
        ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    } catch (error: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    private fun quarterTurned(orientation: Int) = when (orientation) {
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_TRANSVERSE,
        ExifInterface.ORIENTATION_ROTATE_270 -> true
        else -> false
    }

    private fun isAnimated(file: File, mime: String?): Boolean {
        if (mime != "image/gif" && mime != "image/webp") return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return mime == "image/gif"
        return try {
            val drawable = ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) { decoder, _, _ ->
                // Whether it moves is all that is wanted: decode a tiny frame.
                decoder.setTargetSize(1, 1)
            }
            drawable is AnimatedImageDrawable
        } catch (error: Exception) {
            mime == "image/gif"
        }
    }

    /** Scales [source] so its displayed long side is [targetLong], and turns it upright. */
    private fun transformed(source: Bitmap, orientation: Int, targetLong: Int): Bitmap {
        val longSide = max(source.width, source.height)
        val scale = if (longSide <= targetLong) 1f else targetLong.toFloat() / longSide
        val matrix = Matrix().apply {
            postScale(scale, scale)
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    postRotate(90f)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    postRotate(-90f)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(-90f)
            }
        }
        if (matrix.isIdentity) return source
        val result = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (result !== source) source.recycle()
        return result
    }

    /** A JPEG has no alpha: transparent pixels go over white, not black. */
    private fun flattened(source: Bitmap): Bitmap {
        if (!source.hasAlpha()) return source
        val flat = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        Canvas(flat).apply {
            drawColor(Color.WHITE)
            drawBitmap(source, 0f, 0f, null)
        }
        source.recycle()
        return flat
    }

    private fun write(bitmap: Bitmap, quality: Int, output: String?): Map<String, Any?> {
        val q = quality.coerceIn(1, 100)
        if (output != null) {
            val file = File(output)
            file.delete()
            FileOutputStream(file).use { compress(bitmap, q, it) }
            return mapOf("width" to bitmap.width, "height" to bitmap.height, "size" to file.length())
        }
        val bytes = ByteArrayOutputStream().also { compress(bitmap, q, it) }.toByteArray()
        return mapOf(
            "width" to bitmap.width,
            "height" to bitmap.height,
            "size" to bytes.size,
            "bytes" to bytes,
        )
    }

    private fun compress(bitmap: Bitmap, quality: Int, out: OutputStream) {
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) {
            throw CaptureException.failed("cannot encode a JPEG")
        }
    }
}
