package dev.mpx.transfer

import android.app.ActivityManager
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.File
import java.util.UUID

/**
 * The process's one OS envelope on Android: a user-initiated data transfer
 * job on Android 14 and later, a `dataSync` foreground service before.
 *
 * It holds the process up while the Dart engine moves the bytes; it counts
 * nothing itself. The Dart side starts, updates and stops it over the
 * plugin channel; the system and the user end it through the job, the
 * service and the notification, and those ends go back as the seam's
 * events. Every call runs on the main thread.
 */
object EnvelopeHost {
    /** The job id of the user-initiated job. */
    const val JOB_ID = 0x6d707874

    /** The shortest time between two notification posts. */
    const val MIN_POST_INTERVAL_MS = 1000L

    /** How long the foreground service has to come up before a refusal. */
    const val FOREGROUND_START_TIMEOUT_MS = 5000L

    private const val PREFS = "dev.mpx.transfer.envelope"
    private const val PREF_LIVE_HANDLE = "liveHandle"
    private const val PREF_LOG_BYTES = "logBytes"

    /** One started envelope. */
    class Session(val handle: String, val kind: EnvelopeKind, var content: EnvelopeContent) {
        var jobService: JobService? = null
        var jobParams: JobParameters? = null
        var service: Service? = null

        /** Answers the Dart start once the foreground service is up. */
        var pendingStart: ((Map<String, Any?>) -> Unit)? = null
        var lastPostMs = 0L
        var postScheduled = false
    }

    private lateinit var context: Context
    private val handler by lazy { Handler(Looper.getMainLooper()) }
    private var initialized = false

    /** The native diagnostics: logcat, then Dart or the ring. */
    val log = EnvelopeLog(null)

    /** The envelope started now, or null. */
    var session: Session? = null
        private set

    /** Takes a seam event while Dart is attached. */
    private var events: ((Map<String, Any?>) -> Unit)? = null
    private val pendingEvents = mutableListOf<Map<String, Any?>>()

    // The last content shown, for a foreground service that comes up after
    // its envelope was stopped and must still call startForeground once.
    private var lastContent: EnvelopeContent? = null

    // --- Lifecycle -----------------------------------------------------------

    /**
     * Readies the host in this process: the ring file, and the report of an
     * envelope a dead process left live (a low-memory kill, a stop of the
     * whole app), whose job is cancelled so the next run starts afresh.
     */
    fun init(appContext: Context) {
        if (initialized) return
        initialized = true
        context = appContext.applicationContext
        val prefs = prefs()
        val logBytes = prefs.getLong(PREF_LOG_BYTES, NativeRingLog.DEFAULT_MAX_BYTES)
        log.ring = NativeRingLog(ringFile(), logBytes)
        val leftover = prefs.getString(PREF_LIVE_HANDLE, null) ?: return
        prefs.edit().remove(PREF_LIVE_HANDLE).apply()
        var cause = "stop"
        var timeMs = System.currentTimeMillis()
        var exitReason: Int? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = context.getSystemService(ActivityManager::class.java)
            val exit = try {
                manager?.getHistoricalProcessExitReasons(null, 0, 1)?.firstOrNull()
            } catch (error: Exception) {
                // The end is still reported, as a stop, with no exit reason.
                log.note(EnvelopeLevel.WARNING, "envelope exit reasons unreadable", error)
                null
            }
            if (exit != null) {
                cause = EnvelopeRules.causeForExitReason(exit.reason)
                timeMs = exit.timestamp
                exitReason = exit.reason
            }
        }
        log.record(
            EnvelopeLevel.WARNING,
            "systemEnded",
            fields = buildMap {
                put("cause", cause)
                put("handle", leftover)
                put("processEnded", true)
                if (exitReason != null) put("exitReason", exitReason)
            },
            timeMs = timeMs,
        )
        if (Build.VERSION.SDK_INT >= EnvelopeRules.UIDT_MIN_SDK) {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        }
        EnvelopeNotifications.cancel(context)
    }

    /**
     * Attaches a Dart side: from now on records cross to it through
     * [onRecord] and seam events through [onEvent]. [logBytes] is the
     * ring's size from now on. Answers the ring's records (now emptied) and
     * the live handles.
     */
    fun attach(
        logBytes: Long,
        onRecord: (Map<String, Any?>) -> Unit,
        onEvent: (Map<String, Any?>) -> Unit,
    ): Map<String, Any?> {
        if (logBytes > 0 && logBytes != log.ring?.maxBytes) {
            prefs().edit().putLong(PREF_LOG_BYTES, logBytes).apply()
            log.ring = NativeRingLog(ringFile(), logBytes)
        }
        val records = log.drainRing()
        log.sink = onRecord
        events = onEvent
        val pending = pendingEvents.toList()
        pendingEvents.clear()
        pending.forEach(onEvent)
        return mapOf(
            "records" to records,
            "live" to listOfNotNull(session?.handle),
        )
    }

    /**
     * The Dart side went away (its engine was destroyed): nothing moves
     * the bytes any more, so the envelope ends here.
     */
    fun detach() {
        log.sink = null
        events = null
        val ended = session ?: return
        end(ended)
        log.record(EnvelopeLevel.INFO, "withdrawn", ended.content.shownJob, mapOf("why" to "detached"))
    }

    // --- Dart calls ----------------------------------------------------------

    /**
     * Starts an envelope over [content] and answers through [answer]:
     * `{handle, kind}` or `{refused: code}`. A refusal is caught here; the
     * Dart side then runs the jobs in process.
     */
    fun start(content: EnvelopeContent, answer: (Map<String, Any?>) -> Unit) {
        session?.let(::end)
        lastContent = content
        val kind = EnvelopeRules.kindFor(Build.VERSION.SDK_INT)
        if (!isVisible()) return refuse(answer, kind, "notVisible")
        val handle = "android-${UUID.randomUUID()}"
        when (kind) {
            EnvelopeKind.UIDT -> startJob(handle, content, answer)
            EnvelopeKind.DATA_SYNC -> startService(handle, content, answer)
        }
    }

    /** Takes over the live envelope [handle], now showing [content]. */
    fun adopt(handle: String, content: EnvelopeContent) {
        val current = session
        if (current == null || current.handle != handle) {
            log.record(EnvelopeLevel.INFO, "withdrawn", content.shownJob, mapOf("why" to "notLive"))
            return
        }
        update(content)
    }

    /** Mirrors the engine's progress into the notification. */
    fun update(content: EnvelopeContent) {
        val current = session ?: return
        current.content = content
        lastContent = content
        schedulePost(current)
    }

    /** Ends the envelope: its jobs drained or left it. */
    fun stop() {
        val current = session
        if (current != null) {
            end(current)
            return
        }
        // None started in this run: end one a job of an earlier run holds.
        if (Build.VERSION.SDK_INT >= EnvelopeRules.UIDT_MIN_SDK) {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        }
        EnvelopeNotifications.cancel(context)
    }

    // --- System and user callbacks -----------------------------------------

    /** The user-initiated job started: it shows the notification. */
    fun onJobStarted(service: JobService, params: JobParameters): Boolean {
        val current = session
        if (current == null || current.kind != EnvelopeKind.UIDT) {
            log.record(EnvelopeLevel.INFO, "withdrawn", fields = mapOf("why" to "noSession"))
            return false
        }
        current.jobService = service
        current.jobParams = params
        post(current)
        return true
    }

    /** The system stopped the job; Dart's jobs pause until the foreground. */
    fun onJobStopped(params: JobParameters) {
        val current = session ?: return
        if (current.kind != EnvelopeKind.UIDT) return
        val reason = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.stopReason else -1
        endBySystem(current, EnvelopeRules.causeForStopReason(reason))
    }

    /** The foreground service is up: it must call startForeground now. */
    fun onServiceStarted(service: Service) {
        val current = session
        val content = current?.content ?: lastContent
        if (current == null || current.kind != EnvelopeKind.DATA_SYNC || content == null) {
            // Stopped before it came up; startForegroundService still asks
            // for one startForeground, or the system ends the app.
            content?.let {
                try {
                    foreground(service, "stopped", it)
                } catch (error: Exception) {
                    // The service stops next either way; only the log is left.
                    log.note(EnvelopeLevel.WARNING, "envelope stopped foreground refused", error)
                }
            }
            service.stopSelf()
            return
        }
        try {
            foreground(service, current.handle, content)
        } catch (error: Exception) {
            val code = if (error is SecurityException) "securityException" else "notAllowed"
            session = null
            service.stopSelf()
            current.pendingStart?.let { refuse(it, current.kind, code) }
            current.pendingStart = null
            return
        }
        current.service = service
        current.lastPostMs = SystemClock.elapsedRealtime()
        markLive(current.handle)
        current.pendingStart?.invoke(started(current))
        current.pendingStart = null
    }

    /** The service hit its time limit, or the system destroyed it. */
    fun onServiceEnded(service: Service, cause: String) {
        val current = session ?: return
        if (current.service !== service) return
        endBySystem(current, cause)
    }

    /** The user chose "cancel all" on the notification of [handle]. */
    fun onCancelAll(handle: String?) {
        val current = session
        if (current == null || current.handle != handle) {
            EnvelopeNotifications.cancel(context)
            return
        }
        end(current)
        val sink = events
        if (sink != null) {
            log.record(EnvelopeLevel.INFO, "userCancelledAll", current.content.shownJob, bridge = false)
            sink(mapOf("type" to "userCancelledAll"))
        } else {
            log.record(
                EnvelopeLevel.INFO,
                "userCancelledAll",
                current.content.shownJob,
                mapOf("jobs" to current.content.jobs.size),
            )
        }
    }

    /** The user tapped the notification that showed job [jobId]. */
    fun onNotificationTap(jobId: String) {
        log.record(EnvelopeLevel.INFO, "notificationTap", jobId, bridge = false)
        val event = mapOf("type" to "notificationTap", "job" to jobId)
        val sink = events
        if (sink != null) sink(event) else pendingEvents.add(event)
    }

    // --- Starting --------------------------------------------------------------

    private fun startJob(handle: String, content: EnvelopeContent, answer: (Map<String, Any?>) -> Unit) {
        val kind = EnvelopeKind.UIDT
        if (Build.VERSION.SDK_INT < EnvelopeRules.UIDT_MIN_SDK) return refuse(answer, kind, "platform")
        if (!granted("android.permission.RUN_USER_INITIATED_JOBS")) {
            return refuse(answer, kind, "securityException")
        }
        val scheduler = context.getSystemService(JobScheduler::class.java)
            ?: return refuse(answer, kind, "schedulerRefused")
        val upload: Long = content.total ?: JobInfo.NETWORK_BYTES_UNKNOWN.toLong()
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, MpxTransferJobService::class.java))
            .setUserInitiated(true)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            // The system sizes the job's run by its bytes; `system` jobs are
            // uploads first, so the total counts as upload bytes.
            .setEstimatedNetworkBytes(JobInfo.NETWORK_BYTES_UNKNOWN.toLong(), upload)
            .build()
        val result = try {
            scheduler.schedule(job)
        } catch (error: SecurityException) {
            return refuse(answer, kind, "securityException")
        } catch (error: Exception) {
            return refuse(answer, kind, "schedulerRefused")
        }
        if (result != JobScheduler.RESULT_SUCCESS) return refuse(answer, kind, "schedulerRefused")
        val created = Session(handle, kind, content)
        session = created
        markLive(handle)
        answer(started(created))
    }

    private fun startService(handle: String, content: EnvelopeContent, answer: (Map<String, Any?>) -> Unit) {
        val kind = EnvelopeKind.DATA_SYNC
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !granted("android.permission.FOREGROUND_SERVICE")) {
            return refuse(answer, kind, "securityException")
        }
        val created = Session(handle, kind, content)
        created.pendingStart = answer
        session = created
        val intent = Intent(context, MpxTransferDataSyncService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (error: SecurityException) {
            session = null
            return refuse(answer, kind, "securityException")
        } catch (error: Exception) {
            // ForegroundServiceStartNotAllowedException and the background
            // start limits are IllegalStateExceptions.
            session = null
            return refuse(answer, kind, "notVisible")
        }
        handler.postDelayed({
            val pending = created.pendingStart ?: return@postDelayed
            created.pendingStart = null
            if (session === created) end(created)
            refuse(pending, kind, "timeout")
        }, FOREGROUND_START_TIMEOUT_MS)
    }

    private fun foreground(service: Service, handle: String, content: EnvelopeContent) {
        val notification = EnvelopeNotifications.build(context, handle, content)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            service.startForeground(
                EnvelopeNotifications.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            service.startForeground(EnvelopeNotifications.NOTIFICATION_ID, notification)
        }
    }

    private fun started(session: Session): Map<String, Any?> =
        mapOf("handle" to session.handle, "kind" to session.kind.wireName)

    // The engine reports the refusal from this answer; logcat keeps it too.
    private fun refuse(answer: (Map<String, Any?>) -> Unit, kind: EnvelopeKind, code: String) {
        log.record(EnvelopeLevel.WARNING, "refused", fields = mapOf("kind" to kind.wireName, "code" to code), bridge = false)
        answer(mapOf("refused" to code))
    }

    // --- Ending ----------------------------------------------------------------

    /** Ends [ended] here: the job finished or the service stopped. */
    private fun end(ended: Session) {
        if (session === ended) session = null
        clearLive()
        when (ended.kind) {
            EnvelopeKind.UIDT -> {
                val params = ended.jobParams
                val service = ended.jobService
                if (params != null && service != null) {
                    service.jobFinished(params, false)
                } else if (Build.VERSION.SDK_INT >= EnvelopeRules.UIDT_MIN_SDK) {
                    context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
                }
            }
            EnvelopeKind.DATA_SYNC -> ended.service?.let { service ->
                service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
                service.stopSelf()
            }
        }
        EnvelopeNotifications.cancel(context)
    }

    private fun endBySystem(ended: Session, cause: String) {
        end(ended)
        val sink = events
        if (sink != null) {
            log.record(EnvelopeLevel.WARNING, "systemEnded", ended.content.shownJob, mapOf("cause" to cause), bridge = false)
            sink(mapOf("type" to "systemEnded", "cause" to cause))
        } else {
            log.record(
                EnvelopeLevel.WARNING,
                "systemEnded",
                ended.content.shownJob,
                mapOf("cause" to cause, "kind" to ended.kind.wireName, "jobs" to ended.content.jobs.size),
            )
        }
    }

    // --- Notification ----------------------------------------------------------

    // Android drops notification updates that come faster than about one a
    // second, the newest included; a trailing post keeps the last value.
    private fun schedulePost(current: Session) {
        if (current.postScheduled) return
        val wait = current.lastPostMs + MIN_POST_INTERVAL_MS - SystemClock.elapsedRealtime()
        if (wait <= 0) {
            post(current)
            return
        }
        current.postScheduled = true
        handler.postDelayed({
            current.postScheduled = false
            if (session === current) post(current)
        }, wait)
    }

    private fun post(current: Session) {
        val notification = EnvelopeNotifications.build(context, current.handle, current.content)
        when (current.kind) {
            EnvelopeKind.UIDT -> {
                val params = current.jobParams ?: return
                val service = current.jobService ?: return
                if (Build.VERSION.SDK_INT >= EnvelopeRules.UIDT_MIN_SDK) {
                    service.setNotification(
                        params,
                        EnvelopeNotifications.NOTIFICATION_ID,
                        notification,
                        JobService.JOB_END_NOTIFICATION_POLICY_REMOVE,
                    )
                }
            }
            EnvelopeKind.DATA_SYNC -> {
                if (current.service == null) return
                EnvelopeNotifications.post(context, notification)
            }
        }
        current.lastPostMs = SystemClock.elapsedRealtime()
        val content = current.content
        val fraction = EnvelopeRules.progressViewOf(content.done, content.total, null, null).fraction
        log.record(
            EnvelopeLevel.TRACE,
            "progressPushed",
            content.shownJob,
            buildMap {
                put("jobs", content.jobs.size)
                if (fraction != null) put("fraction", fraction)
            },
        )
    }

    // --- Support -----------------------------------------------------------------

    private fun isVisible(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    private fun granted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun markLive(handle: String) {
        prefs().edit().putString(PREF_LIVE_HANDLE, handle).apply()
    }

    private fun clearLive() {
        prefs().edit().remove(PREF_LIVE_HANDLE).apply()
    }

    private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun ringFile() = File(File(context.noBackupFilesDir, "mpx_transfer"), "envelope_log.jsonl")
}
