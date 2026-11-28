package dev.mpx.library

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * The access saving needs on Android, answered as the Dart side's save
 * access map (`scope`, `status`).
 *
 * On API 29 and later an app needs no permission to add media and
 * downloads it owns to the MediaStore, so every destination is
 * `authorized` with scope `none`. On 28 and below the gallery and
 * Downloads are files under the public directories, which need
 * `WRITE_EXTERNAL_STORAGE`; the host declares it with
 * `android:maxSdkVersion="28"` (README). The system save dialog needs
 * nothing anywhere.
 *
 * A permission the host did not declare cannot be granted, so it is
 * `restricted`; one asked for and not granted is `denied`.
 */
internal class SaveAccess(private val context: Context) {
    private val prefs = context.getSharedPreferences("dev.mpx.library.save", Context.MODE_PRIVATE)

    /** Whether the permission was asked for once; Android itself does not say. */
    var asked: Boolean
        get() = prefs.getBoolean("asked", false)
        set(value) = prefs.edit().putBoolean("asked", value).apply()

    /** Whether saving to [destination] needs the legacy write permission. */
    fun needsPermission(destination: String): Boolean =
        destination != "ask" && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    fun answer(destination: String): Map<String, Any> {
        if (!needsPermission(destination)) return mapOf("scope" to "none", "status" to "authorized")
        val status = when {
            ContextCompat.checkSelfPermission(context, PERMISSION) ==
                PackageManager.PERMISSION_GRANTED -> "authorized"
            !declared() -> "restricted"
            asked -> "denied"
            else -> "notDetermined"
        }
        return mapOf("scope" to "legacyWrite", "status" to status)
    }

    private fun declared(): Boolean {
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        return info.requestedPermissions?.contains(PERMISSION) == true
    }

    companion object {
        const val PERMISSION = Manifest.permission.WRITE_EXTERNAL_STORAGE
    }
}
