package dev.mpx.player

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture

/**
 * Keeps the sound owner playing while the app is in the background: a media
 * session on its ExoPlayer inside a foreground media service, with the
 * system's media notification.
 *
 * Opt-in on two sides. Dart passes `backgroundAudio: true`, and the host
 * declares the service in its own manifest (the plugin's manifest does not,
 * so apps without background audio get no foreground-service permission):
 *
 * ```xml
 * <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
 * <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
 * <service
 *     android:name="dev.mpx.player.MpxPlaybackService"
 *     android:foregroundServiceType="mediaPlayback"
 *     android:exported="true">
 *   <intent-filter>
 *     <action android:name="androidx.media3.session.MediaSessionService" />
 *   </intent-filter>
 * </service>
 * ```
 */
@UnstableApi
class MpxPlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        current?.let { attach(it) }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onDestroy() {
        session?.release()
        session = null
        if (running === this) running = null
        super.onDestroy()
    }

    private fun attach(player: Player) {
        val existing = session
        if (existing == null) {
            session = MediaSession.Builder(this, player).build()
        } else if (existing.player !== player) {
            existing.player = player
        }
    }

    companion object {
        private var running: MpxPlaybackService? = null
        private var current: Player? = null

        internal fun show(player: Player) {
            current = player
            running?.attach(player)
        }

        internal fun forget(player: Player) {
            if (current !== player) return
            current = null
            running?.let { service ->
                service.session?.release()
                service.session = null
            }
        }
    }
}

/**
 * Connects the sound owner's player to [MpxPlaybackService] while background
 * audio is on and the host declared the service; Media3 moves the service
 * into the foreground while the session's player plays and out when it stops.
 */
@UnstableApi
internal class MpxBackgroundAudio(private val context: Context) {
    var enabled = false
        set(value) {
            field = value
            if (!value) disconnect()
        }

    private var controller: ListenableFuture<MediaController>? = null
    private var player: Player? = null

    private val declared: Boolean by lazy {
        val intent =
            Intent(MediaSessionService.SERVICE_INTERFACE).setPackage(context.packageName)
        context.packageManager.queryIntentServices(intent, 0).any {
            it.serviceInfo.name == MpxPlaybackService::class.java.name
        }
    }

    /** [audible] is the player with sound now, or null. */
    fun update(audible: Player?) {
        if (!enabled || !declared) return
        if (audible == null || audible === player) return
        player = audible
        MpxPlaybackService.show(audible)
        if (controller == null) {
            val token =
                SessionToken(context, ComponentName(context, MpxPlaybackService::class.java))
            controller = MediaController.Builder(context, token).buildAsync()
        }
    }

    /** [released] is going away: no session may keep it. */
    fun forget(released: Player) {
        if (player !== released) return
        MpxPlaybackService.forget(released)
        player = null
        disconnect()
    }

    private fun disconnect() {
        player?.let { MpxPlaybackService.forget(it) }
        player = null
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
    }
}
