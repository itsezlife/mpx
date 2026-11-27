package dev.mpx.transfer

import android.app.job.JobParameters
import android.app.job.JobService

/**
 * The user-initiated data transfer job of the envelope (Android 14 and
 * later). It does no work: it holds the process up and shows the shared
 * notification while the Dart engine moves the bytes.
 */
class MpxTransferJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        EnvelopeHost.init(this)
        return EnvelopeHost.onJobStarted(this, params)
    }

    // Not rescheduled: the engine resumes the jobs from its journal once the
    // app is in the foreground again.
    override fun onStopJob(params: JobParameters): Boolean {
        EnvelopeHost.onJobStopped(params)
        return false
    }
}
