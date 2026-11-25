package dev.mpx

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel

/**
 * Streams device signals to Dart: one full reading (network class, power
 * saving, thermal status, battery level, media volume) on listen and another whenever any of them changes.
 *
 * Readings are sent on the main thread; the network callback runs on a
 * system thread, so its updates are posted there.
 */
internal class DeviceSignalsStream(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val audio = context.getSystemService(AudioManager::class.java)

    private var sink: EventChannel.EventSink? = null
    private var network = "none"
    private var lastSent: Map<String, Any>? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(net: Network, capabilities: NetworkCapabilities) {
            val next = classify(capabilities)
            main.post { network = next; send() }
        }

        override fun onLost(net: Network) {
            main.post { network = "none"; send() }
        }
    }

    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = send()
    }

    // The media volume changes with a key and with the slider: the system says
    // so in a broadcast that is not in the SDK's constants but has been sent
    // since the first release, with the stream it was for.
    private val volumeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val stream = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
            if (stream == AudioManager.STREAM_MUSIC) send()
        }
    }

    // The battery is a sticky broadcast: registering for it with no receiver
    // returns the current state, and a receiver hears every change.
    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = send()
    }

    // Typed as Any so the class loads below API 29, where the listener
    // interface does not exist.
    private var thermalListener: Any? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        network = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.let(::classify) ?: "none"
        connectivity.registerDefaultNetworkCallback(networkCallback)
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            // A system broadcast still reaches a receiver that is not exported.
            context.registerReceiver(powerSaveReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(powerSaveReceiver, filter)
        }
        val volume = IntentFilter("android.media.VOLUME_CHANGED_ACTION")
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(volumeReceiver, volume, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(volumeReceiver, volume)
        }
        val battery = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(batteryReceiver, battery, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(batteryReceiver, battery)
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val listener = PowerManager.OnThermalStatusChangedListener { send() }
            power.addThermalStatusListener(context.mainExecutor, listener)
            thermalListener = listener
        }
        send()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        lastSent = null
        connectivity.unregisterNetworkCallback(networkCallback)
        context.unregisterReceiver(powerSaveReceiver)
        context.unregisterReceiver(batteryReceiver)
        context.unregisterReceiver(volumeReceiver)
        if (Build.VERSION.SDK_INT >= 29) {
            (thermalListener as? PowerManager.OnThermalStatusChangedListener)
                ?.let(power::removeThermalStatusListener)
            thermalListener = null
        }
        main.removeCallbacksAndMessages(null)
    }

    private fun send() {
        val events = sink ?: return
        val reading = mapOf(
            "network" to network,
            "powerSaving" to power.isPowerSaveMode,
            "thermal" to thermal(),
            "batteryLevel" to batteryLevel(),
            "mediaVolume" to mediaVolume(),
        )
        if (reading == lastSent) return
        lastSent = reading
        events.success(reading)
    }

    // The media volume as a percentage of its range, 0 when muted.
    private fun mediaVolume(): Int {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return -1
        return Math.round(audio.getStreamVolume(AudioManager.STREAM_MUSIC) * 100f / max)
    }

    // The percentage, or -1 when the system cannot say.
    private fun batteryLevel(): Int {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return -1
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return -1
        return Math.round(level * 100f / scale)
    }

    private fun classify(capabilities: NetworkCapabilities): String {
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "none"
        val unmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            (Build.VERSION.SDK_INT >= 30 &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED))
        if (unmetered) return "unmetered"
        val roaming = Build.VERSION.SDK_INT >= 28 &&
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING)
        return if (roaming) "roaming" else "metered"
    }

    // Android's seven thermal steps fold into the four the Dart side knows.
    // Below API 29 there is no thermal status; it reads nominal.
    private fun thermal(): String {
        if (Build.VERSION.SDK_INT < 29) return "nominal"
        return when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT,
            PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
    }
}
