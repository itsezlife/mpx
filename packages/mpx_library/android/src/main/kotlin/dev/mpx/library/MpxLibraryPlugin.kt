package dev.mpx.library

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native side of mpx_library on Android: the MediaStore library on one
 * method channel, its events (access, changes) on one event channel.
 * Queries run on a small pool; answers go back on the main thread.
 *
 * The plugin declares no permission: the host's manifest does (README). A
 * permission the host did not declare is answered as not granted.
 */
class MpxLibraryPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var library: MediaStoreLibrary
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val pool: ExecutorService = Executors.newFixedThreadPool(3)
    private val accessReplies = mutableListOf<MethodChannel.Result>()
    private val cancels = ConcurrentHashMap<Int, CancellationSignal>()
    internal var intake: SystemCameraIntake? = null

    // MediaStore tells no detail and fires in bursts; the Dart side
    // debounces them into one reload.
    private val observer = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            sink?.success(mapOf("type" to "changed"))
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        library = MediaStoreLibrary(context)
        methods = MethodChannel(binding.binaryMessenger, "dev.mpx.library/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "dev.mpx.library/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        onCancel(null)
        pool.shutdown()
    }

    // --- Activity and permissions ---

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
        intake = SystemCameraIntake(binding).also { binding.addActivityResultListener(it) }
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        intake?.let { activity?.removeActivityResultListener(it); it.abandon() }
        intake = null
        activity = null
        answerAccess()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != ACCESS_REQUEST) return false
        answerAccess()
        return true
    }

    private fun requestAccess(result: MethodChannel.Result) {
        val host: Activity = activity?.activity ?: return result.success(library.access())
        accessReplies += result
        if (accessReplies.size > 1) return
        library.asked = true
        host.requestPermissions(library.permissions(), ACCESS_REQUEST)
    }

    private fun answerAccess() {
        val access = library.access()
        accessReplies.forEach { it.success(access) }
        accessReplies.clear()
        sink?.success(access + ("type" to "access"))
    }

    private fun openSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        (activity?.activity ?: context).startActivity(intent)
    }

    // --- Events ---

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val resolver = context.contentResolver
        for (uri in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Images.Media.INTERNAL_CONTENT_URI,
            MediaStore.Video.Media.INTERNAL_CONTENT_URI,
        )) {
            resolver.registerContentObserver(uri, true, observer)
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        context.contentResolver.unregisterContentObserver(observer)
    }

    // --- Methods ---

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "access" -> result.success(library.access())
            "requestAccess" -> requestAccess(result)
            // Asking again makes Android 14 show its choice of items again.
            "manageSelected" -> requestAccess(result)
            "openSettings" -> {
                openSettings()
                result.success(null)
            }
            "albums" -> background(result) { library.albums() }
            "page" -> background(result) {
                library.page(
                    call.argument<String>("album") ?: "all",
                    call.argument<Int>("offset") ?: 0,
                    call.argument<Int>("limit") ?: 0,
                )
            }
            "thumbnail" -> background(result) {
                library.thumbnail(
                    call.argument<String>("id") ?: "",
                    call.argument<Int>("pixels") ?: 256,
                    CancellationSignal(),
                )
            }
            "original" -> {
                val request = call.argument<Int>("request") ?: 0
                val cancel = CancellationSignal().also { cancels[request] = it }
                background(result, after = { cancels.remove(request) }) {
                    library.original(call.argument<String>("id") ?: "", cancel)
                }
            }
            "cancelOriginal" -> {
                cancels.remove(call.argument<Int>("request"))?.cancel()
                result.success(null)
            }
            "releaseOriginal" -> {
                call.argument<String>("path")?.let { path -> pool.execute { library.release(path) } }
                result.success(null)
            }
            "systemCamera" -> {
                val camera = intake ?: return result.error("unavailable", "no activity", null)
                camera.capture(call.argument<String>("kind") ?: "photo", result)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(
        result: MethodChannel.Result,
        after: () -> Unit = {},
        work: () -> Any?,
    ) {
        pool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: LibraryError) {
                main.post { result.error(error.code, error.message, null) }
            } catch (error: SecurityException) {
                main.post { result.error("unavailable", error.message, null) }
            } catch (error: Exception) {
                main.post { result.error("failed", error.message ?: "$error", null) }
            } finally {
                after()
            }
        }
    }
}

private const val ACCESS_REQUEST = 0x6d6c
