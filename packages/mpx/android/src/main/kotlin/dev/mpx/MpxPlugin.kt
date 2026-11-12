package dev.mpx

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** Registers the native side of mpx: the device signals event channel. */
class MpxPlugin : FlutterPlugin {
    private var deviceSignals: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        deviceSignals = EventChannel(binding.binaryMessenger, "dev.mpx.device_signals").apply {
            setStreamHandler(DeviceSignalsStream(binding.applicationContext))
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        deviceSignals?.setStreamHandler(null)
        deviceSignals = null
    }
}
