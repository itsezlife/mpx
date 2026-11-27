package dev.mpx.transfer

import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The native part of mpx_transfer on Android: the OS envelope
 * ([EnvelopeHost]) over the channel `dev.mpx.transfer/envelope`.
 *
 * The transfer engine runs in Dart; this side only holds the process up,
 * shows the shared notification and reports what the system and the user
 * did to it. Notification taps reach it through the launch activity's
 * intents.
 */
class MpxTransferPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.NewIntentListener {
    companion object {
        /** The channel the Dart side's `AndroidTransferEnvelope` talks on. */
        const val CHANNEL = "dev.mpx.transfer/envelope"
    }

    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        EnvelopeHost.init(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        // Only the engine whose Dart side attached owns the envelope.
        if (attached) EnvelopeHost.detach()
        attached = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attach" -> {
                val channel = channel ?: return result.error("detached", null, null)
                attached = true
                val logBytes = call.argument<Number>("logBytes")?.toLong() ?: 0L
                result.success(
                    EnvelopeHost.attach(
                        logBytes,
                        onRecord = { channel.invokeMethod("record", it) },
                        onEvent = { channel.invokeMethod("event", it) },
                    ),
                )
            }
            "start" -> EnvelopeHost.start(contentOf(call)) { result.success(it) }
            "adopt" -> {
                EnvelopeHost.adopt(call.argument<String>("handle") ?: "", contentOf(call))
                result.success(null)
            }
            "update" -> {
                EnvelopeHost.update(contentOf(call))
                result.success(null)
            }
            "stop" -> {
                EnvelopeHost.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun contentOf(call: MethodCall): EnvelopeContent = EnvelopeContent(
        jobs = call.argument<List<String>>("jobs") ?: emptyList(),
        shownJob = call.argument("shownJob"),
        done = call.argument<Number>("done")?.toLong() ?: 0L,
        total = call.argument<Number>("total")?.toLong(),
        title = call.argument("title") ?: "",
        text = call.argument("text"),
        cancelAllLabel = call.argument("cancelAllLabel"),
        progressText = call.argument("progressText"),
        icon = call.argument("icon"),
    )

    // --- Notification taps ------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        takeTap(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean = takeTap(intent)

    // The extra is removed once taken, so a recreated activity holding the
    // same intent does not report the tap twice.
    private fun takeTap(intent: Intent?): Boolean {
        val job = intent?.getStringExtra(EnvelopeNotifications.EXTRA_TAP_JOB) ?: return false
        intent.removeExtra(EnvelopeNotifications.EXTRA_TAP_JOB)
        EnvelopeHost.onNotificationTap(job)
        return false
    }
}
