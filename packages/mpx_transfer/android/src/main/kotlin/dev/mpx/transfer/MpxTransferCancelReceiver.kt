package dev.mpx.transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Takes the notification's "cancel all" to the envelope. */
class MpxTransferCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != EnvelopeNotifications.ACTION_CANCEL_ALL) return
        EnvelopeHost.init(context)
        EnvelopeHost.onCancelAll(intent.getStringExtra(EnvelopeNotifications.EXTRA_HANDLE))
    }
}
