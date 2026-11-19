package dev.mpx.library

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * The system camera intake: `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE`
 * writing into a file of the plugin's cache folder, shared with the camera
 * app through the plugin's file provider. Answers the file's facts, or null
 * when the user cancelled.
 *
 * A host whose manifest declares `CAMERA` must hold it before the system
 * camera may be called (Android refuses the intent otherwise); it is asked
 * for here then. A host that declares nothing needs nothing.
 */
class SystemCameraIntake(private val binding: ActivityPluginBinding) :
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private var pending: Pair<File, MethodChannel.Result>? = null
    private var waiting: (() -> Unit)? = null

    init {
        binding.addRequestPermissionsResultListener(this)
    }

    fun capture(kind: String, result: MethodChannel.Result) {
        if (pending != null) return result.error("failed", "a capture is already open", null)
        val activity = binding.activity
        if (declaresCamera(activity) &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            waiting = {
                if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    launch(kind, result)
                } else {
                    result.error("permission", "camera not allowed", null)
                }
            }
            activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_REQUEST)
            return
        }
        launch(kind, result)
    }

    private fun launch(kind: String, result: MethodChannel.Result) {
        val activity = binding.activity
        val video = kind == "video"
        val folder = File(activity.cacheDir, "mpx_library/camera").apply { mkdirs() }
        val file = File(folder, "camera-${System.currentTimeMillis()}.${if (video) "mp4" else "jpg"}")
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.mpx_library.files", file)
        val intent = Intent(if (video) MediaStore.ACTION_VIDEO_CAPTURE else MediaStore.ACTION_IMAGE_CAPTURE)
            .putExtra(MediaStore.EXTRA_OUTPUT, uri)
            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        pending = file to result
        try {
            activity.startActivityForResult(intent, CAPTURE_REQUEST)
        } catch (error: Exception) {
            pending = null
            result.error("unavailable", error.message ?: "no camera app", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != CAPTURE_REQUEST) return false
        val (file, result) = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || !file.isFile || file.length() == 0L) {
            file.delete()
            result.success(null)
            return true
        }
        result.success(
            mapOf(
                "path" to file.path,
                "name" to file.name,
                "size" to file.length(),
                "mime" to if (file.extension == "mp4") "video/mp4" else "image/jpeg",
                "modifiedMs" to file.lastModified(),
            ),
        )
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != CAMERA_REQUEST) return false
        val next = waiting
        waiting = null
        next?.invoke()
        return true
    }

    /** Answers what is open and forgets it: the activity went away. */
    fun abandon() {
        binding.removeRequestPermissionsResultListener(this)
        pending?.second?.success(null)
        pending = null
    }

    @Suppress("DEPRECATION")
    private fun declaresCamera(activity: Activity): Boolean {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            activity.packageManager.getPackageInfo(
                activity.packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
            )
        } else {
            activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
        }
        return info.requestedPermissions?.contains(Manifest.permission.CAMERA) == true
    }
}

private const val CAPTURE_REQUEST = 0x6d63
private const val CAMERA_REQUEST = 0x6d64
