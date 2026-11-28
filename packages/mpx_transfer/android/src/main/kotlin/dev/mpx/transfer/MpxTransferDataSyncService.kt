package dev.mpx.transfer

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * The `dataSync` foreground service of the envelope (before Android 14). It
 * does no work: it holds the process up and shows the shared notification
 * while the Dart engine moves the bytes.
 */
class MpxTransferDataSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        EnvelopeHost.init(this)
        EnvelopeHost.onServiceStarted(this)
        // Not restarted after a kill: the engine resumes from its journal.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        EnvelopeHost.onServiceEnded(this, "timeLimit")
        stopSelf()
    }

    override fun onDestroy() {
        EnvelopeHost.onServiceEnded(this, "stop")
        super.onDestroy()
    }
}
