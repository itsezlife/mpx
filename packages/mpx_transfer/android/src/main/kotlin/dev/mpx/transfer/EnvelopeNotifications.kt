package dev.mpx.transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build

/** What the shared notification shows, as the Dart side last sent it. */
data class EnvelopeContent(
    val jobs: List<String>,
    val shownJob: String?,
    val done: Long,
    val total: Long?,
    val title: String,
    val text: String?,
    val cancelAllLabel: String?,
    val progressText: String?,
    val icon: String?,
)

/**
 * The one notification every job in the envelope shares: the host's title,
 * text and icon, the engine's progress, a tap that opens the app with the
 * shown job's id, and "cancel all".
 */
object EnvelopeNotifications {
    /** The id of the shared notification. */
    const val NOTIFICATION_ID = 0x6d7078

    /** The notification channel of the envelope. */
    const val CHANNEL_ID = "mpx_transfer_envelope"

    /** The launch intent's extra naming the job a tap showed. */
    const val EXTRA_TAP_JOB = "dev.mpx.transfer.TAP_JOB"

    /** The cancel-all broadcast's extra naming the envelope's handle. */
    const val EXTRA_HANDLE = "dev.mpx.transfer.HANDLE"

    /** The action of the cancel-all broadcast. */
    const val ACTION_CANCEL_ALL = "dev.mpx.transfer.CANCEL_ALL"

    /** The notification for [content] of the envelope [handle]. */
    fun build(context: Context, handle: String, content: EnvelopeContent): Notification {
        ensureChannel(context, content.title)
        val view = EnvelopeRules.progressViewOf(
            content.done,
            content.total,
            content.text,
            content.progressText,
        )
        val icon = iconOf(context, content.icon)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(icon)
            .setContentTitle(content.title)
            .setProgress(view.max, view.progress, view.indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
        view.contentText?.let(builder::setContentText)
        view.subText?.let(builder::setSubText)
        tapIntent(context, content.shownJob)?.let(builder::setContentIntent)
        val cancelLabel = content.cancelAllLabel ?: context.getString(android.R.string.cancel)
        builder.addAction(
            Notification.Action.Builder(
                Icon.createWithResource(context, icon),
                cancelLabel,
                cancelIntent(context, handle),
            ).build(),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    /** Takes the shared notification down. */
    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    /** Shows [notification] as the shared one. */
    fun post(context: Context, notification: Notification) {
        context.getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, notification)
    }

    // The channel's name is the host's title: mpx holds no strings, and the
    // title is already localised. Creating it again updates the name.
    private fun ensureChannel(context: Context, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    // The host's drawable (then mipmap) by name; the app's icon without one.
    private fun iconOf(context: Context, name: String?): Int {
        if (name != null) {
            for (type in listOf("drawable", "mipmap")) {
                @Suppress("DiscouragedApi")
                val id = context.resources.getIdentifier(name, type, context.packageName)
                if (id != 0) return id
            }
        }
        val appIcon = context.applicationInfo.icon
        return if (appIcon != 0) appIcon else android.R.drawable.stat_sys_upload
    }

    private fun tapIntent(context: Context, job: String?): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (job != null) launch.putExtra(EXTRA_TAP_JOB, job)
        return PendingIntent.getActivity(
            context,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun cancelIntent(context: Context, handle: String): PendingIntent {
        val intent = Intent(context, MpxTransferCancelReceiver::class.java)
            .setAction(ACTION_CANCEL_ALL)
            .putExtra(EXTRA_HANDLE, handle)
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
