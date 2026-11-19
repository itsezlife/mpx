package dev.mpx.capture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native side of mpx_capture: one method channel for commands, one event
 * channel for job progress. Every job event is a map with `job` and `type`
 * (see the Dart `CaptureChannel`). Events are sent on the main thread.
 */
class MpxCapturePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: ActivityPluginBinding? = null
    private val permissionReplies = mutableListOf<MethodChannel.Result>()
    private val recorders = mutableMapOf<Int, RoundVideoRecorder>()
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val background: ExecutorService = Executors.newSingleThreadExecutor()
    // Media preparation runs two items at a time (ADR 0011).
    private val preparation: ExecutorService = Executors.newFixedThreadPool(2)
    private lateinit var transcoder: CaptureTranscoder

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        transcoder = CaptureTranscoder(context, ::emit)
        methods = MethodChannel(binding.binaryMessenger, "dev.mpx.capture/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.mpx.capture/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        transcoder.cancelAll()
        recorders.values.toList().forEach { it.cancel() }
        recorders.clear()
        background.shutdown()
        preparation.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        // A request no activity can answer stays unanswered: deny it.
        permissionReplies.forEach { it.success(false) }
        permissionReplies.clear()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val granted = RoundVideoRecorder.hasPermissions(context)
        permissionReplies.forEach { it.success(granted) }
        permissionReplies.clear()
        return true
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        if (RoundVideoRecorder.hasPermissions(context)) return result.success(true)
        val host: Activity = activity?.activity ?: return result.success(false)
        permissionReplies += result
        if (permissionReplies.size > 1) return
        host.requestPermissions(
            arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST,
        )
    }

    private fun startRound(call: MethodCall, result: MethodChannel.Result) {
        val config = try {
            RoundVideoConfig.from(call)
        } catch (error: CaptureException) {
            return result.error(error.code, error.message, null)
        }
        val recorder = RoundVideoRecorder(
            context, config, textures, ::emit,
            onFinish = { recorders.remove(config.job) },
        )
        recorders[config.job] = recorder
        recorder.start { outcome ->
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { error ->
                    val failure = error as? CaptureException
                        ?: CaptureException.failed(error.message ?: "$error")
                    result.error(failure.code, failure.message, null)
                },
            )
        }
    }

    /** Runs [work] on a preparation thread and answers on the main thread. */
    private fun prepare(result: MethodChannel.Result, work: () -> Map<String, Any?>) {
        preparation.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: CaptureException) {
                main.post { result.error(error.code, error.message, null) }
            } catch (error: Exception) {
                main.post { result.error("failed", error.message ?: "$error", null) }
            } catch (error: OutOfMemoryError) {
                main.post { result.error("failed", "out of memory", null) }
            }
        }
    }

    private fun <T> MethodCall.need(key: String): T =
        argument<T>(key) ?: throw CaptureException.failed("$method: missing $key")

    private fun recorder(call: MethodCall): RoundVideoRecorder? =
        call.argument<Int>("job")?.let { recorders[it] }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("failed", "probe needs a path", null)
                background.execute {
                    try {
                        val info = CaptureTranscoder.probe(path)
                        main.post { result.success(info) }
                    } catch (error: CaptureException) {
                        main.post { result.error(error.code, error.message, null) }
                    }
                }
            }
            "stillProbe" -> prepare(result) {
                StillCodec.probe(call.need("path"))
            }
            "stillEncode" -> prepare(result) {
                StillCodec.encode(
                    call.need("path"),
                    call.need("maxSide"),
                    call.need("quality"),
                    call.argument<String>("output"),
                )
            }
            "videoThumbnail" -> prepare(result) {
                StillCodec.videoThumbnail(call.need("path"), call.need("maxSide"), call.need("quality"))
            }
            "compress" -> {
                try {
                    transcoder.enqueue(CompressionRequest.from(call))
                    result.success(null)
                } catch (error: CaptureException) {
                    result.error(error.code, error.message, null)
                }
            }
            "cancel" -> {
                val job = call.argument<Int>("job")
                if (job != null) transcoder.cancel(job)
                // The reply waits until the recording's file is deleted.
                val recorder = job?.let { recorders.remove(it) }
                if (recorder == null) result.success(null) else recorder.cancel { result.success(null) }
            }
            "permissions" -> requestPermissions(result)
            "roundStart" -> startRound(call, result)
            "roundPause" -> {
                recorder(call)?.pause()
                result.success(null)
            }
            "roundResume" -> {
                recorder(call)?.resume()
                result.success(null)
            }
            "roundSwitchCamera" -> {
                val recorder = recorder(call) ?: return result.success(null)
                recorder.switchCamera { result.success(it) }
            }
            "roundStop" -> {
                recorder(call)?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

private const val PERMISSION_REQUEST = 0x6d70

/** An error that crosses the channel; [code] picks the Dart exception. */
class CaptureException(val code: String, override val message: String) : Exception(message) {
    fun event(job: Int): Map<String, Any?> =
        mapOf("job" to job, "type" to "error", "code" to code, "message" to message)

    companion object {
        fun failed(message: String) = CaptureException("failed", message)
        fun permission(message: String) = CaptureException("permission", message)
    }
}
