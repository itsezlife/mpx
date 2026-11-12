package dev.mpx

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel

/**
 * Streams device signals to Dart: one full reading (network class, power
 * saving, thermal status) on listen and another whenever any of them changes.
 *
 * Readings are sent on the main thread; the network callback runs on a
 * system thread, so its updates are posted there.
 */
internal class DeviceSignalsStream(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)

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
        )
        if (reading == lastSent) return
        lastSent = reading
        events.success(reading)
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
