package dev.mpx.transfer

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * The native part of mpx_transfer on Android.
 *
 * Empty for now: the transfer engine runs in Dart, and the OS envelope that
 * keeps a `system` transfer alive in the background is added here later.
 */
class MpxTransferPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
