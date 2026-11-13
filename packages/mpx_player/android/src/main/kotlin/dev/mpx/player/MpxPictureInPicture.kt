package dev.mpx.player

import android.app.Activity
import android.app.Application
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.view.ViewTreeObserver

/**
 * Android's picture in picture is the activity's: the whole Flutter view
 * shrinks into the window and the player's texture keeps playing in it.
 *
 * The host's activity must declare `android:supportsPictureInPicture="true"`
 * (and `android:resizeableActivity="true"`). The user expanding the window
 * shows on the activity's layout and resume; closing it stops the activity.
 * [stop] expands the window by bringing the activity to the front.
 */
internal class MpxPictureInPicture(
    private val report: (playerId: Long, active: Boolean, dismissed: Boolean) -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private var activity: Activity? = null
    private var shown: Long? = null

    // Entering and leaving the window always resizes it; a resumed activity
    // may stay resumed through both, so the layout is the reliable signal.
    private val onLayout = ViewTreeObserver.OnGlobalLayoutListener { activity?.let(::checkExpanded) }

    fun attach(activity: Activity) {
        detach()
        this.activity = activity
        activity.application.registerActivityLifecycleCallbacks(this)
        activity.window.decorView.viewTreeObserver.addOnGlobalLayoutListener(onLayout)
    }

    fun detach() {
        activity?.window?.decorView?.viewTreeObserver?.removeOnGlobalLayoutListener(onLayout)
        activity?.application?.unregisterActivityLifecycleCallbacks(this)
        activity = null
    }

    val isSupported: Boolean
        get() {
            val current = activity ?: return false
            return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                current.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        }

    /** Moves the activity into the window, shaped like [aspect] (w to h). */
    fun start(playerId: Long, aspect: Pair<Int, Int>?) {
        val current = activity ?: return
        if (!isSupported || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val params = PictureInPictureParams.Builder()
        aspect?.let { (width, height) -> params.setAspectRatio(clamp(width, height)) }
        val entered =
            try {
                current.enterPictureInPictureMode(params.build())
            } catch (error: IllegalStateException) {
                // The activity does not declare picture-in-picture support.
                Log.w(TAG, "picture in picture refused: ${error.message}")
                false
            }
        if (!entered) return
        shown = playerId
        report(playerId, true, false)
    }

    /**
     * The platform gives an app no call to close its window: bringing the
     * activity back to the front expands it.
     */
    fun stop() {
        val current = activity ?: return
        if (shown == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || !current.isInPictureInPictureMode) {
            return end(dismissed = false)
        }
        current.startActivity(
            Intent(current, current.javaClass).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
        )
        end(dismissed = false)
    }

    /** The player that left the engine while in the window. */
    fun forget(playerId: Long) {
        if (shown == playerId) end(dismissed = false)
    }

    private fun end(dismissed: Boolean) {
        val id = shown ?: return
        shown = null
        report(id, false, dismissed)
    }

    // Expanding the window shows on the layout (the activity may stay
    // resumed throughout).
    private fun checkExpanded(activity: Activity) {
        if (activity !== this.activity || shown == null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && activity.isInPictureInPictureMode) {
            return
        }
        end(dismissed = false)
    }

    override fun onActivityResumed(activity: Activity) = checkExpanded(activity)

    // An activity in the window stops only when the window closes (or the
    // screen goes off): it still reads as in picture in picture then.
    override fun onActivityStopped(activity: Activity) {
        if (activity === this.activity) end(dismissed = true)
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

    override fun onActivityStarted(activity: Activity) {}

    override fun onActivityPaused(activity: Activity) {}

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

    override fun onActivityDestroyed(activity: Activity) {}

    companion object {
        private const val TAG = "mpx_player"

        // The platform accepts aspect ratios between 1:2.39 and 2.39:1.
        private fun clamp(width: Int, height: Int): Rational {
            val ratio = width.toDouble() / height
            return when {
                ratio > 2.39 -> Rational(239, 100)
                ratio < 1 / 2.39 -> Rational(100, 239)
                else -> Rational(width, height)
            }
        }
    }
}
