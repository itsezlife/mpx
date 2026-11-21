package dev.mpx.capture

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.util.Range
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
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

    // Set by a switch until the new camera's first frame, which Dart hears
    // as `firstFrame`: until then the texture holds the old camera's frames.
    @Volatile private var awaitingFirstFrame = false

    // Completed captures still to see before the frames count as back: the
    // first completes before its frame reaches the texture.
    @Volatile private var capturesToWait = 0
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
                trace("surface available")
                if (!closed) preview?.setSurfaceProvider(executor, ::provideSurface)
            }

            override fun onSurfaceCleanup() {
                trace("surface cleanup")
            }
        })
    }

    private fun awaitFrames() {
        capturesToWait = 3
        awaitingFirstFrame = true
    }

    // The session's lifecycle in logcat, tag `mpx.capture`.
    private fun trace(what: String) = android.util.Log.d("mpx.capture", "session $id $what")

    // --- Controls ---

    fun open(done: (Map<String, Any?>) -> Unit) {
        trace("open")
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
        trace("cap $fps")
        frameRateCap = fps
        applyFrameRate()
    }

    fun switchCamera(): String {
        val provider = provider ?: return facing
        val next = if (facing == "front") "back" else "front"
        if (!provider.hasCamera(selector(next))) return facing
        facing = next
        // A new camera starts at its own 1x.
        zoomRatio = 1f
        awaitFrames()
        bind()
        return facing
    }

    // The zoom ratio (1 = the main camera's own view); kept across rebinds
    // of the same camera.
    private var zoomRatio = 1f

    private fun zoomRange(): Pair<Float, Float> {
        val state = camera?.cameraInfo?.zoomState?.value ?: return 1f to 1f
        return state.minZoomRatio to state.maxZoomRatio
    }

    /** Zooms to the ratio [value], clamped to the camera's range. */
    fun setZoomFactor(value: Double) {
        val (min, max) = zoomRange()
        zoomRatio = value.toFloat().coerceIn(min, max)
        camera?.cameraControl?.setZoomRatio(zoomRatio)
    }

    /**
     * Sets the exposure compensation from -1 (darkest) to 1 (brightest)
     * over the camera's range; nothing where the camera has none.
     */
    fun setExposure(value: Double) {
        val camera = camera ?: return
        val state = camera.cameraInfo.exposureState
        if (!state.isExposureCompensationSupported) return
        val range = state.exposureCompensationRange
        val v = value.coerceIn(-1.0, 1.0)
        val index = if (v >= 0) Math.round(v * range.upper).toInt() else Math.round(-v * range.lower).toInt()
        camera.cameraControl.setExposureCompensationIndex(index)
    }

    // Preset ratios: the wide lens when the camera reaches below 1x, 1x, and
    // 2x when it reaches that far.
    private fun lenses(min: Float, max: Float): List<Double> = buildList {
        if (min < 0.95f) add(Math.round(min * 10) / 10.0)
        add(1.0)
        if (max >= 2f) add(2.0)
    }

    /**
     * Focuses and meters at ([x], [y]) of the preview as shown, 0 to 1 from
     * its top left; the focus holds until the next one.
     */
    fun focusAt(x: Double, y: Double) {
        val camera = camera ?: return
        // A preview mirrored for the front camera shows x flipped.
        val shownX = if (facing == "front") 1 - x else x
        val point = androidx.camera.core.SurfaceOrientedMeteringPointFactory(1f, 1f)
            .createPoint(shownX.toFloat(), y.toFloat())
        camera.cameraControl.startFocusAndMetering(
            androidx.camera.core.FocusMeteringAction.Builder(point).disableAutoCancel().build(),
        )
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
        trace("pause")
        if (!closed) lifecycleRegistry.currentState = Lifecycle.State.CREATED
    }

    fun resume() {
        trace("resume")
        awaitFrames()
        if (!closed) lifecycleRegistry.currentState = Lifecycle.State.STARTED
    }

    fun capturePhoto(output: String, mirrorFront: Boolean, done: (Result<Map<String, Any?>>) -> Unit) {
        val capture = imageCapture
            ?: return done(Result.failure(CaptureException.failed("camera not available")))
        val file = File(output).apply { delete() }
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file)
                // Saved as the preview shows it: the flip lands in the EXIF
                // orientation with the rotation.
                .setMetadata(
                    ImageCapture.Metadata().apply {
                        isReversedHorizontal = mirrorFront && facing == "front"
                    },
                )
                .build(),
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
        if (recording != null) return Result.failure(CaptureException.failed("already recording"))
        val capture = videoCapture ?: bindVideo()
            ?: return Result.failure(CaptureException.failed("video not available on this camera"))
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
        trace("close")
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
        trace("bind $facing")
        val provider = provider ?: return
        if (!provider.hasCamera(selector(facing))) {
            facing = if (facing == "front") "back" else "front"
            if (!provider.hasCamera(selector(facing))) return failOpen()
        }
        provider.unbind(*listOfNotNull<UseCase>(preview, imageCapture, videoCapture).toTypedArray())
        videoCapture = null
        val preview = previewBuilder().build().also { this.preview = it }
        val imageCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
            .also { this.imageCapture = it }
        preview.setSurfaceProvider(executor, ::provideSurface)
        // Preview and photos only: the video use case (its encoder, its
        // recorder) joins when a recording starts and leaves when it ends,
        // so browsing never builds an encoder.
        camera = try {
            provider.bindToLifecycle(this, selector(facing), preview, imageCapture)
        } catch (error: Exception) {
            return failOpen()
        }
        setFlash(flash)
        setZoomFactor(zoomRatio.toDouble())
        applyFrameRate()
        emitState()
    }

    // The video use case for one recording, beside the bound preview and
    // photos; null when the camera cannot stream the three at once.
    private fun bindVideo(): VideoCapture<Recorder>? {
        val provider = provider ?: return null
        trace("bind video")
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(
                    Quality.FHD,
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                ),
            )
            .build()
        val capture = VideoCapture.withOutput(recorder)
        return try {
            camera = provider.bindToLifecycle(this, selector(facing), capture)
            videoCapture = capture
            applyFrameRate()
            capture
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    private fun unbindVideo() {
        val capture = videoCapture ?: return
        trace("unbind video")
        videoCapture = null
        provider?.unbind(capture)
    }

    // A preview whose first completed capture after a switch tells Dart the
    // new camera's frames have started.
    @SuppressLint("UnsafeOptInUsageError")
    private fun previewBuilder(): Preview.Builder {
        val builder = Preview.Builder()
        Camera2Interop.Extender(builder).setSessionCaptureCallback(
            object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    if (!awaitingFirstFrame) return
                    if (--capturesToWait > 0) return
                    awaitingFirstFrame = false
                    main.post {
                        if (closed || opened != null || previewWidth == 0) return@post
                        emit(
                            state("available") +
                                mapOf("job" to id, "type" to "camera", "firstFrame" to true),
                        )
                    }
                }
            },
        )
        return builder
    }

    private fun provideSurface(request: androidx.camera.core.SurfaceRequest) {
        trace("surface request ${request.resolution}")
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
        unbindVideo()
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
        "microphone" to microphoneAccess(context),
    ) + zoomFacts()

    private fun zoomFacts(): Map<String, Any?> {
        val (min, max) = zoomRange()
        return mapOf(
            "minZoom" to min.toDouble(),
            "maxZoom" to max.toDouble(),
            "zoomFactor" to zoomRatio.coerceIn(min, max).toDouble(),
            "lenses" to lenses(min, max),
            "hasExposure" to (camera?.cameraInfo?.exposureState?.isExposureCompensationSupported ?: false),
        )
    }

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

        /** Set when the user refused the microphone since the app started. */
        @Volatile var microphoneRefused = false

        /** "granted", "denied" (refused since the app started) or "notDetermined". */
        fun microphoneAccess(context: Context) = when {
            hasMicrophone(context) -> "granted"
            microphoneRefused -> "denied"
            else -> "notDetermined"
        }
    }
}
