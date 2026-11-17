package dev.mpx.mpx_example

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var labChannel: MethodChannel? = null
    private var labReceiver: BroadcastReceiver? = null

    /// The performance lab's channel. It stays inert until a lab build
    /// (`--dart-define=MPX_LAB=true`) asks for `install`: only then is the
    /// `lab.SET` receiver registered, so a regular build listens to nothing.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAB_CHANNEL)
        labChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    registerLabReceiver()
                    result.success(
                        mapOf(
                            "filesDir" to getExternalFilesDir(null)?.path,
                            // `am start ... --es lab_items 30`: switches in
                            // force before the first frame.
                            "extras" to extrasOf(intent, prefix = "lab_"),
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun registerLabReceiver() {
        if (labReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                labChannel?.invokeMethod("set", extrasOf(intent, prefix = ""))
            }
        }
        labReceiver = receiver
        val filter = IntentFilter("lab.SET")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    override fun onDestroy() {
        labReceiver?.let(::unregisterReceiver)
        labReceiver = null
        super.onDestroy()
    }

    /// The intent's extras whose names start with [prefix], every value as
    /// its text (`--es key items --es value 30`, `--ez value true`).
    private fun extrasOf(intent: Intent?, prefix: String): Map<String, String> {
        val extras = intent?.extras ?: return emptyMap()
        return extras.keySet()
            .filter { it.startsWith(prefix) }
            .associate { name ->
                @Suppress("DEPRECATION")
                name.removePrefix(prefix) to extras.get(name).toString()
            }
    }

    companion object {
        private const val LAB_CHANNEL = "mpx_example/lab"
    }
}
