package dev.mpx.library

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of mpx_library: one method channel. The MediaStore library
 * adapter and the intake routes answer on it as they land; until then every
 * call is not implemented.
 */
class MpxLibraryPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "dev.mpx.library/methods")
        methods.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        result.notImplemented()
    }
}
