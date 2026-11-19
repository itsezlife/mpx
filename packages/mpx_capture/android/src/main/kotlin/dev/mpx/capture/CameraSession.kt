package dev.mpx.capture

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.util.Range
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor

/**
 * One live camera for the Dart `CameraSession`: CameraX Preview into a
 * Flutter surface producer, ImageCapture for photos and VideoCapture (a
 * Recorder writing H.264 and AAC into an MP4) for videos, bound to a
 * lifecycle of its own. Pause moves the lifecycle to CREATED (the camera
 * closes, the use cases stay bound); resume moves it back to STARTED.
 *
 * Every call and callback runs on the main thread. Events go out as
 * `{job: id, type: camera, ...}` maps (the Dart `CaptureChannel`).
 */
class CameraSession(
    private val context: Context,
    val id: Int,
    textures: TextureRegistry,
    private val emit: (Map<String, Any?>) -> Unit,
    private var facing: String,
    private var frameRateCap: Int?,
    private val audio: Boolean,
) : LifecycleOwner {
    private val main = Handler(Looper.getMainLooper())
    private val executor: Executor = ContextCompat.getMainExecutor(context)
    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private val producer = textures.createSurfaceProducer()
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var recordingPath: String? = null
    private var recordingDone: ((Result<Map<String, Any?>>) -> Unit)? = null
    private var flash = "off"
    private var quarterTurns = 0
    private var previewWidth = 0
    private var previewHeight = 0
    private var opened: ((Map<String, Any?>) -> Unit)? = null
    private var closed = false

    init {
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                // The engine made a new surface (the app came back): hand it
                // to the camera through a fresh surface request.
                if (!closed) preview?.setSurfaceProvider(executor, ::provideSurface)
            }

            override fun onSurfaceCleanup() {}
        })
    }

    // --- Controls ---

    fun open(done: (Map<String, Any?>) -> Unit) {
        if (!hasCamera(context)) return done(mapOf("state" to "denied"))
        opened = done
        lifecycleRegistry.currentState = Lifecycle.State.STARTED
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (closed) return@addListener
            try {
                provider = future.get()
                bind()
            } catch (error: Exception) {
                failOpen()
            }
        }, executor)
        main.postDelayed({ if (opened != null) failOpen() }, 5000)
    }

    fun setFrameRateCap(fps: Int?) {
        frameRateCap = fps
        applyFrameRate()
    }

    fun switchCamera(): String {
        val provider = provider ?: return facing
        val next = if (facing == "front") "back" else "front"
        if (!provider.hasCamera(selector(next))) return facing
        facing = next
        bind()
        return facing
    }

    fun setFlash(mode: String) {
        flash = mode
        imageCapture?.flashMode = when (mode) {
            "on" -> ImageCapture.FLASH_MODE_ON
            "auto" -> ImageCapture.FLASH_MODE_AUTO
            else -> ImageCapture.FLASH_MODE_OFF
        }
    }

    fun pause() {
        if (!closed) lifecycleRegistry.currentState = Lifecycle.State.CREATED
    }

    fun resume() {
        if (!closed) lifecycleRegistry.currentState = Lifecycle.State.STARTED
    }

    fun capturePhoto(output: String, done: (Result<Map<String, Any?>>) -> Unit) {
        val capture = imageCapture
            ?: return done(Result.failure(CaptureException.failed("camera not available")))
        val file = File(output).apply { delete() }
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            executor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(result: ImageCapture.OutputFileResults) {
                    done(
                        runCatching {
                            val facts = StillCodec.probe(output)
                            mapOf(
                                "path" to output,
                                "size" to file.length(),
                                "width" to facts["width"],
                                "height" to facts["height"],
                            )
                        },
                    )
                }

                override fun onError(error: ImageCaptureException) {
                    file.delete()
                    done(Result.failure(CaptureException.failed(error.message ?: "photo failed")))
                }
            },
        )
    }

    @SuppressLint("MissingPermission")
    fun startRecording(output: String): Result<Unit> {
        val capture = videoCapture
            ?: return Result.failure(CaptureException.failed("video not available on this camera"))
        if (recording != null) return Result.failure(CaptureException.failed("already recording"))
        val file = File(output).apply { delete() }
        recordingPath = output
        var pending = capture.output.prepareRecording(context, FileOutputOptions.Builder(file).build())
        if (audio && hasMicrophone(context)) pending = pending.withAudioEnabled()
        if (flash == "on") camera?.cameraControl?.enableTorch(true)
        recording = pending.start(executor) { event ->
            if (event is VideoRecordEvent.Finalize) finishRecording(event)
        }
        return Result.success(Unit)
    }

    fun stopRecording(done: (Result<Map<String, Any?>>) -> Unit) {
        val current = recording
            ?: return done(Result.failure(CaptureException.failed("not recording")))
        recordingDone = done
        current.stop()
    }

    fun close() {
        if (closed) return
        closed = true
        recording?.close()
        recording = null
        recordingDone?.invoke(Result.failure(CaptureException.failed("camera session closed")))
        recordingDone = null
        opened = null
        provider?.unbind(*listOfNotNull<UseCase>(preview, imageCapture, videoCapture).toTypedArray())
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        producer.release()
    }

    // --- Binding ---

    private fun selector(facing: String) =
        if (facing == "front") CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    private fun bind() {
        val provider = provider ?: return
        if (!provider.hasCamera(selector(facing))) {
            facing = if (facing == "front") "back" else "front"
            if (!provider.hasCamera(selector(facing))) return failOpen()
        }
        provider.unbind(*listOfNotNull<UseCase>(preview, imageCapture, videoCapture).toTypedArray())
        val preview = Preview.Builder().build().also { this.preview = it }
        val imageCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
            .also { this.imageCapture = it }
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(
                    Quality.FHD,
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                ),
            )
            .build()
        val videoCapture = VideoCapture.withOutput(recorder)
        preview.setSurfaceProvider(executor, ::provideSurface)
        camera = try {
            provider.bindToLifecycle(this, selector(facing), preview, imageCapture, videoCapture)
                .also { this.videoCapture = videoCapture }
        } catch (error: IllegalArgumentException) {
            // A camera that cannot stream all three at once still takes
            // photos; recording then reports that it is unavailable.
            this.videoCapture = null
            try {
                provider.bindToLifecycle(this, selector(facing), preview, imageCapture)
            } catch (error: Exception) {
                return failOpen()
            }
        }
        setFlash(flash)
        applyFrameRate()
        emitState()
    }

    private fun provideSurface(request: androidx.camera.core.SurfaceRequest) {
        if (closed) {
            request.willNotProvideSurface()
            return
        }
        previewWidth = request.resolution.width
        previewHeight = request.resolution.height
        producer.setSize(previewWidth, previewHeight)
        request.setTransformationInfoListener(executor) { info ->
            val turns = if (producer.handlesCropAndRotation()) 0 else info.rotationDegrees / 90
            if (turns != quarterTurns) {
                quarterTurns = turns
                emitState()
            }
        }
        request.provideSurface(producer.surface, executor) {}
        val waiting = opened
        if (waiting != null) {
            opened = null
            waiting(state("available"))
        } else {
            emitState()
        }
    }

    // Camera2 interop is marked experimental; it is the one way to change the
    // frame-rate range of a bound camera without a rebind (a restart).
    @SuppressLint("UnsafeOptInUsageError")
    private fun applyFrameRate() {
        val camera = camera ?: return
        val control = Camera2CameraControl.from(camera.cameraControl)
        val cap = frameRateCap
        if (cap == null) {
            control.clearCaptureRequestOptions()
            return
        }
        val ranges = Camera2CameraInfo.from(camera.cameraInfo)
            .getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return
        // The highest top at or under the cap, then the widest such range.
        val range = ranges.filter { it.upper <= cap }
            .sortedWith(compareByDescending<Range<Int>> { it.upper }.thenBy { it.lower })
            .firstOrNull() ?: return
        control.setCaptureRequestOptions(
            CaptureRequestOptions.Builder()
                .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
                .build(),
        )
    }

    // --- Recording ---

    private fun finishRecording(event: VideoRecordEvent.Finalize) {
        camera?.cameraControl?.enableTorch(false)
        recording = null
        val path = recordingPath
        recordingPath = null
        val done = recordingDone
        recordingDone = null
        val failed = event.error != VideoRecordEvent.Finalize.ERROR_NONE &&
            event.error != VideoRecordEvent.Finalize.ERROR_DURATION_LIMIT_REACHED &&
            event.error != VideoRecordEvent.Finalize.ERROR_FILE_SIZE_LIMIT_REACHED
        if (path == null || done == null) return
        if (failed || !File(path).isFile) {
            File(path).delete()
            return done(Result.failure(CaptureException.failed("recording failed (${event.error})")))
        }
        done(runCatching { videoFacts(path, event.recordingStats.recordedDurationNanos / 1000) })
    }

    private fun videoFacts(path: String, durationUs: Long): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            val turned = rotation % 180 != 0
            return mapOf(
                "path" to path,
                "size" to File(path).length(),
                "width" to maxOf(1, if (turned) height else width),
                "height" to maxOf(1, if (turned) width else height),
                "durationUs" to durationUs,
            )
        } finally {
            retriever.release()
        }
    }

    // --- State ---

    private fun state(name: String): Map<String, Any?> = mapOf(
        "state" to name,
        "textureId" to producer.id(),
        "previewWidth" to previewWidth,
        "previewHeight" to previewHeight,
        "quarterTurns" to quarterTurns,
        "facing" to facing,
        "hasFlash" to (camera?.cameraInfo?.hasFlashUnit() ?: false),
        "canSwitch" to canSwitch(),
    )

    private fun canSwitch(): Boolean {
        val provider = provider ?: return false
        return provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) &&
            provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)
    }

    private fun emitState() {
        if (closed || opened != null || previewWidth == 0) return
        emit(state("available") + mapOf("job" to id, "type" to "camera"))
    }

    private fun failOpen() {
        val waiting = opened ?: return emit(mapOf("job" to id, "type" to "camera", "state" to "failed"))
        opened = null
        waiting(mapOf("state" to "failed"))
    }

    companion object {
        fun hasCamera(context: Context) =
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED

        fun hasMicrophone(context: Context) =
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
    }
}
