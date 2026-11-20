package dev.mpx.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

/**
 * The app's audio focus as the Dart player pool's sound owner uses it.
 *
 * Requested while one player is audible and abandoned when none is, as the
 * mode says: `exclusive` takes focus (other apps pause), `duck` asks them
 * to lower their sound, `mix` takes none and plays over them. A
 * transient loss (a call, an alarm, a duck request) reports `interrupted`,
 * a permanent one `lost`, a regain `gained`; headphones coming out while
 * focus is held report `outputRemoved`. The pool decides what each means.
 */
internal class MpxAudioFocus(
    private val context: Context,
    private val report: (NativeAudioFocusChange) -> Unit,
) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var held = false
    private var request: AudioFocusRequest? = null

    private val listener =
        AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> report(NativeAudioFocusChange.GAINED)
                AudioManager.AUDIOFOCUS_LOSS -> report(NativeAudioFocusChange.LOST)
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                -> report(NativeAudioFocusChange.INTERRUPTED)
            }
        }

    private val noisy =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    report(NativeAudioFocusChange.OUTPUT_REMOVED)
                }
            }
        }

    fun request(mode: NativeAudioFocusMode) {
        if (held) return
        held = true
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        // A system broadcast reaches a receiver that is not exported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(noisy, filter)
        }
        // Mixing asks for nothing: the music that plays goes on.
        if (mode == NativeAudioFocusMode.MIX) return
        val gain =
            if (mode == NativeAudioFocusMode.DUCK) {
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            } else {
                AudioManager.AUDIOFOCUS_GAIN
            }
        val result =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val made =
                    AudioFocusRequest.Builder(gain)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                                .build(),
                        )
                        // A call later gives focus back with GAIN.
                        .setAcceptsDelayedFocusGain(true)
                        // Video is often speech: pause rather than duck.
                        .setWillPauseWhenDucked(true)
                        .setOnAudioFocusChangeListener(listener)
                        .build()
                request = made
                audio.requestAudioFocus(made)
            } else {
                @Suppress("DEPRECATION")
                audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, gain)
            }
        when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_FAILED -> report(NativeAudioFocusChange.LOST)
            // Granted later (a call is on): pause until GAIN arrives.
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> report(NativeAudioFocusChange.INTERRUPTED)
        }
    }

    fun abandon() {
        if (!held) return
        held = false
        context.unregisterReceiver(noisy)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            request?.let { audio.abandonAudioFocusRequest(it) }
            request = null
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(listener)
        }
    }
}
