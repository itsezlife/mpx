package dev.mpx.capture

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native side of mpx_capture: one method channel for commands, one event
 * channel for job progress. Every job event is a map with `job` and `type`
 * (see the Dart `CaptureChannel`). Events are sent on the main thread.
 */
class MpxCapturePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val background: ExecutorService = Executors.newSingleThreadExecutor()
    private lateinit var transcoder: CaptureTranscoder

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
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
        background.shutdown()
    }

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
            "compress" -> {
                try {
                    transcoder.enqueue(CompressionRequest.from(call))
                    result.success(null)
                } catch (error: CaptureException) {
                    result.error(error.code, error.message, null)
                }
            }
            "cancel" -> {
                call.argument<Int>("job")?.let { transcoder.cancel(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

/** An error that crosses the channel; [code] picks the Dart exception. */
class CaptureException(val code: String, override val message: String) : Exception(message) {
    fun event(job: Int): Map<String, Any?> =
        mapOf("job" to job, "type" to "error", "code" to code, "message" to message)

    companion object {
        fun failed(message: String) = CaptureException("failed", message)
        fun permission(message: String) = CaptureException("permission", message)
    }
}
