package dev.mpx.capture

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.view.TextureRegistry
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executor
import kotlin.math.abs

/** One round video as the Dart side configured it. */
class RoundVideoConfig(
    val job: Int,
    val output: String,
    val side: Int,
    val videoBitrate: Int,
    val frameRate: Int,
    val audioBitrate: Int,
    val maxDurationUs: Long,
    val camera: String,
) {
    companion object {
        fun from(call: MethodCall): RoundVideoConfig {
            fun <T> need(key: String): T =
                call.argument<T>(key) ?: throw CaptureException.failed("roundStart: missing $key")
            return RoundVideoConfig(
                job = need("job"),
                output = need("output"),
                side = need("side"),
                videoBitrate = need("videoBitrate"),
                frameRate = maxOf(1, need<Int>("frameRate")),
                audioBitrate = need("audioBitrate"),
                maxDurationUs = need<Number>("maxDurationUs").toLong(),
                camera = call.argument<String>("camera") ?: "front",
            )
        }
    }
}

/**
 * Records one round video message: CameraX preview frames into our GL stage,
 * which draws the upright centre square into a MediaCodec H.264 encoder and
 * into the Flutter preview texture; the microphone goes through AudioRecord
 * into an AAC encoder; MediaMuxer writes the MP4.
 *
 * Threads: CameraX binding on the main thread; frames, the video encoder and
 * the end of the recording on the GL thread; audio on its own thread. Paused
 * time is cut out by shifting later timestamps back by the pause.
 */
class RoundVideoRecorder(
    private val context: Context,
    private val config: RoundVideoConfig,
    private val textures: TextureRegistry,
    private val emit: (Map<String, Any?>) -> Unit,
    private val onFinish: () -> Unit,
) : LifecycleOwner {
    private val main = Handler(Looper.getMainLooper())
    private val glThread = HandlerThread("mpx-round-gl").apply { start() }
    private val gl = Handler(glThread.looper)
    private val glExecutor = Executor { gl.post(it) }
    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private val previewSide = maxOf(config.side, 480)
    private val producer = textures.createSurfaceProducer().apply { setSize(previewSide, previewSide) }

    // GL thread state.
    private lateinit var stage: GlStage
    private var cameraTexture = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var bufferSize = Size(640, 480)
    private var rotationDegrees = 0

    // A camera that writes its orientation into the buffer (the
    // SurfaceTexture's matrix carries it) has already turned the frame by
    // the sensor's rotation; what is left of [rotationDegrees] turns here.
    private var cameraTransform = false
    @Volatile private var sensorDegrees = 0
    private val turnDegrees
        get() = if (cameraTransform) (rotationDegrees - sensorDegrees + 360) % 360 else rotationDegrees
    private var encoderSurface: EGLSurface? = null
    private var previewSurface: EGLSurface? = null
    private val surfaceMatrix = FloatArray(16)
    private lateinit var videoEncoder: MediaCodec
    private lateinit var writer: Mp4Writer
    private var started: ((Result<Map<String, Any?>>) -> Unit)? = null
    private var lastReportNs = 0L

    // Shared between threads.
    @Volatile private var facing = config.camera
    @Volatile private var paused = false
    @Volatile private var pausedAtNs = 0L
    @Volatile private var offsetNs = 0L
    @Volatile private var startNs = -1L

    // The clock the camera stamps frames with (monotonic or boot time, by
    // device); pauses and the microphone's samples are timed on the same one.
    @Volatile private var clock: () -> Long = System::nanoTime
    @Volatile private var positionUs = 0L
    @Volatile private var stopping = false
    @Volatile private var finished = false
    @Volatile private var cancelled = false
    private var audio: AudioPump? = null
    private var cameraProvider: ProcessCameraProvider? = null

    // --- Controls (main thread) ---

    fun start(done: (Result<Map<String, Any?>>) -> Unit) {
        if (!hasPermissions(context)) {
            return done(Result.failure(CaptureException.permission("camera or microphone not allowed")))
        }
        lifecycleRegistry.currentState = Lifecycle.State.STARTED
        gl.post {
            try {
                setUpGl()
                started = done
            } catch (error: Exception) {
                fail(error)
                main.post { done(Result.failure(CaptureException.failed(error.message ?: "$error"))) }
                return@post
            }
            main.post { bindCamera() }
            gl.postDelayed({
                val waiting = started ?: return@postDelayed
                started = null
                fail(CaptureException.failed("the camera sent no frames"), report = false)
                main.post { waiting(Result.failure(CaptureException.failed("the camera sent no frames"))) }
            }, 5000)
        }
    }

    fun pause() {
        if (finished || paused) return
        pausedAtNs = clock()
        paused = true
    }

    fun resume() {
        if (finished || !paused) return
        if (startNs >= 0) offsetNs += clock() - pausedAtNs
        paused = false
    }

    fun switchCamera(done: (String) -> Unit) {
        val provider = cameraProvider
        if (finished || provider == null) return done(facing)
        val next = if (facing == "front") "back" else "front"
        if (!provider.hasCamera(selector(next))) return done(facing)
        facing = next
        bindCamera()
        done(facing)
    }

    fun stop() {
        gl.post { finish() }
    }

    /** Stops and deletes the file; [done] runs on the main thread once it is gone. */
    fun cancel(done: () -> Unit = {}) {
        if (finished) return done()
        cancelled = true
        gl.post {
            teardown()
            File(config.output).delete()
            main.post(done)
        }
    }

    // --- Camera (main thread) ---

    private fun selector(facing: String) =
        if (facing == "front") CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    private fun bindCamera() {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (finished) return@addListener
            try {
                val provider = future.get()
                cameraProvider = provider
                if (!provider.hasCamera(selector(facing))) {
                    facing = if (facing == "front") "back" else "front"
                }
                val preview = Preview.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(640, 480),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                    .setTargetFrameRate(Range(config.frameRate, config.frameRate))
                    .build()
                preview.setSurfaceProvider(glExecutor) { request -> provideSurface(request) }
                provider.unbindAll()
                val camera = provider.bindToLifecycle(this, selector(facing), preview)
                sensorDegrees = camera.cameraInfo.sensorRotationDegrees
            } catch (error: Exception) {
                gl.post { fail(error) }
            }
        }, ContextCompat.getMainExecutor(context))
    }

    // --- GL thread ---

    private fun setUpGl() {
        File(config.output).delete()
        stage = GlStage()
        writer = Mp4Writer(config.output)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, config.side, config.side).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, config.videoBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, config.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        videoEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        videoEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoderSurface = stage.windowSurface(videoEncoder.createInputSurface())
        videoEncoder.start()
        audio = AudioPump().also { it.start() }
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                gl.post { attachPreview() }
            }

            override fun onSurfaceCleanup() {
                gl.post { detachPreview() }
            }
        })
        attachPreview()
    }

    private fun attachPreview() {
        if (finished) return
        detachPreview()
        previewSurface = stage.windowSurface(producer.surface)
    }

    private fun detachPreview() {
        previewSurface?.let { stage.releaseSurface(it) }
        previewSurface = null
    }

    private fun provideSurface(request: androidx.camera.core.SurfaceRequest) {
        if (finished) {
            request.willNotProvideSurface()
            return
        }
        val texture = stage.externalTexture()
        val target = SurfaceTexture(texture).apply {
            setDefaultBufferSize(request.resolution.width, request.resolution.height)
            setOnFrameAvailableListener({ onFrame(it, texture) }, gl)
        }
        request.setTransformationInfoListener(glExecutor) { info ->
            rotationDegrees = info.rotationDegrees
            cameraTransform = info.hasCameraTransform()
        }
        val surface = Surface(target)
        request.provideSurface(surface, glExecutor) {
            surface.release()
            target.release()
            if (!finished) stage.deleteTexture(texture)
            if (surfaceTexture === target) surfaceTexture = null
        }
        surfaceTexture = target
        cameraTexture = texture
        bufferSize = request.resolution
    }

    private fun onFrame(target: SurfaceTexture, texture: Int) {
        if (finished || target !== surfaceTexture) return
        target.updateTexImage()
        target.getTransformMatrix(surfaceMatrix)
        val mirrored = facing == "front"
        previewSurface?.let {
            stage.draw(it, previewSide, texture, surfaceMatrix, bufferSize.width, bufferSize.height, rotationDegrees, turnDegrees, mirrored)
        }
        started?.let { done ->
            started = null
            val reply = mapOf(
                "textureId" to producer.id(),
                "previewWidth" to previewSide,
                "previewHeight" to previewSide,
                "camera" to facing,
            )
            main.post { done(Result.success(reply)) }
        }
        if (paused || stopping) return
        val frameNs = target.timestamp
        if (startNs < 0) {
            clock = clockOf(frameNs)
            startNs = frameNs
        }
        val ptsNs = frameNs - startNs - offsetNs
        if (ptsNs < 0) return
        val encoder = encoderSurface ?: return
        stage.draw(encoder, config.side, texture, surfaceMatrix, bufferSize.width, bufferSize.height, rotationDegrees, turnDegrees, mirrored, ptsNs)
        drain(videoEncoder, video = true, endOfStream = false)
        positionUs = ptsNs / 1000
        report()
        if (positionUs >= config.maxDurationUs) finish()
    }

    private fun report() {
        val now = System.nanoTime()
        if (now - lastReportNs < 100_000_000L) return
        lastReportNs = now
        emit(
            mapOf(
                "job" to config.job,
                "type" to "progress",
                "bytes" to File(config.output).length(),
                "positionUs" to positionUs,
                "fraction" to fraction(),
            ),
        )
    }

    private fun fraction(): Double =
        if (config.maxDurationUs > 0) minOf(1.0, positionUs.toDouble() / config.maxDurationUs) else 0.0

    private fun finish() {
        if (stopping || finished || cancelled) return
        stopping = true
        try {
            videoEncoder.signalEndOfInputStream()
            drain(videoEncoder, video = true, endOfStream = true)
            audio?.finish()
            val written = writer.finish()
            teardown()
            if (!written) throw CaptureException.failed("nothing was recorded")
            emit(
                mapOf(
                    "job" to config.job,
                    "type" to "done",
                    "path" to config.output,
                    "size" to File(config.output).length(),
                    "durationUs" to positionUs,
                    "width" to config.side,
                    "height" to config.side,
                    // MediaMuxer patches the media box size in the head on stop.
                    "headerRewritten" to true,
                    "reencoded" to true,
                    "fraction" to fraction(),
                ),
            )
        } catch (error: Exception) {
            fail(error)
        }
    }

    private fun fail(error: Exception, report: Boolean = true) {
        if (finished) return
        teardown()
        File(config.output).delete()
        if (report) {
            val failure = error as? CaptureException ?: CaptureException.failed(error.message ?: "$error")
            emit(failure.event(config.job))
        }
    }

    private fun teardown() {
        if (finished) return
        finished = true
        audio?.cancel()
        main.post {
            cameraProvider?.unbindAll()
            lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
            producer.release()
        }
        runCatching { videoEncoder.stop() }
        runCatching { videoEncoder.release() }
        runCatching { writer.finish() }
        if (::stage.isInitialized) {
            detachPreview()
            encoderSurface?.let { stage.releaseSurface(it) }
            encoderSurface = null
            surfaceTexture?.release()
            surfaceTexture = null
            stage.release()
        }
        glThread.quitSafely()
        main.post(onFinish)
    }

    private fun drain(codec: MediaCodec, video: Boolean, endOfStream: Boolean) {
        val info = MediaCodec.BufferInfo()
        var waits = 0
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream || ++waits > 200) return
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> writer.addTrack(video, codec.outputFormat)
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (buffer != null && info.size > 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        writer.write(video, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    // --- Audio ---

    /** Microphone PCM into an AAC encoder, on its own thread. */
    private inner class AudioPump {
        private val sampleRate = 48_000
        private val chunk = 2048
        private val encoder: MediaCodec
        private val record: AudioRecord
        private val thread = Thread(::run, "mpx-round-audio")
        @Volatile private var ending = false
        @Volatile private var aborted = false
        private var lastPtsUs = -1L

        init {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, config.audioBitrate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, chunk * 2)
            }
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val minimum = AudioRecord.getMinBufferSize(
                sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            record = newRecord(maxOf(minimum, chunk * 4))
        }

        @SuppressLint("MissingPermission") // Checked in start().
        private fun newRecord(bufferSize: Int) = AudioRecord(
            MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, bufferSize,
        )

        fun start() {
            encoder.start()
            record.startRecording()
            thread.start()
        }

        /** Ends the stream and waits until its last sample is written. */
        fun finish() {
            ending = true
            thread.join(3000)
        }

        fun cancel() {
            aborted = true
            ending = true
            if (Thread.currentThread() !== thread) thread.join(1000)
        }

        private fun run() {
            val pcm = ByteArray(chunk)
            try {
                while (!ending) {
                    val read = record.read(pcm, 0, chunk)
                    if (read <= 0) continue
                    val nowNs = clock()
                    if (paused || startNs < 0) continue
                    val durationUs = read / 2 * 1_000_000L / sampleRate
                    var ptsUs = (nowNs - startNs - offsetNs) / 1000 - durationUs
                    if (ptsUs < 0) continue
                    if (ptsUs <= lastPtsUs) ptsUs = lastPtsUs + 1
                    lastPtsUs = ptsUs
                    queue(pcm, read, ptsUs, 0)
                    drain(encoder, video = false, endOfStream = false)
                }
                if (!aborted) {
                    queue(ByteArray(0), 0, maxOf(lastPtsUs + 1, 0), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    drain(encoder, video = false, endOfStream = true)
                }
            } catch (error: Exception) {
                // A failing microphone ends the audio track; the video goes on.
            } finally {
                runCatching { record.stop() }
                record.release()
                runCatching { encoder.stop() }
                encoder.release()
            }
        }

        private fun queue(pcm: ByteArray, size: Int, ptsUs: Long, flags: Int) {
            val index = encoder.dequeueInputBuffer(10_000)
            if (index < 0) return
            val input = encoder.getInputBuffer(index) ?: return
            input.clear()
            input.put(pcm, 0, size)
            encoder.queueInputBuffer(index, 0, size, ptsUs, flags)
        }
    }

    companion object {
        // A frame's timestamp is close to now on its own clock and far off
        // on the other one by the time the device has slept.
        private fun clockOf(frameNs: Long): () -> Long {
            val monotonic = System.nanoTime()
            val boot = SystemClock.elapsedRealtimeNanos()
            return if (abs(frameNs - boot) < abs(frameNs - monotonic)) {
                SystemClock::elapsedRealtimeNanos
            } else {
                System::nanoTime
            }
        }

        fun hasPermissions(context: Context): Boolean =
            listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO).all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
    }
}

/**
 * MediaMuxer that starts once both tracks are known, holding samples that
 * arrive earlier. Called from the GL and the audio thread.
 */
internal class Mp4Writer(path: String, orientationHint: Int = 0) {
    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4).apply {
        if (orientationHint != 0) setOrientationHint(orientationHint)
    }
    private var videoTrack = -1
    private var audioTrack = -1
    private var started = false
    private var closed = false
    private val pending = mutableListOf<Triple<Boolean, ByteBuffer, MediaCodec.BufferInfo>>()

    @Synchronized
    fun addTrack(video: Boolean, format: MediaFormat) {
        if (started || closed) return
        if (video) videoTrack = muxer.addTrack(format) else audioTrack = muxer.addTrack(format)
        if (videoTrack >= 0 && audioTrack >= 0) {
            muxer.start()
            started = true
            for ((isVideo, buffer, info) in pending) {
                muxer.writeSampleData(if (isVideo) videoTrack else audioTrack, buffer, info)
            }
            pending.clear()
        }
    }

    @Synchronized
    fun write(video: Boolean, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (closed) return
        if (started) {
            muxer.writeSampleData(if (video) videoTrack else audioTrack, buffer, info)
            return
        }
        val copy = ByteBuffer.allocateDirect(info.size).put(buffer).apply { flip() }
        val copiedInfo = MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) }
        pending += Triple(video, copy, copiedInfo)
    }

    /** Stops the muxer; true when a file with samples was written. */
    @Synchronized
    fun finish(): Boolean {
        if (closed) return false
        closed = true
        // Video without audio (no microphone samples): start with one track.
        if (!started && videoTrack >= 0 && pending.isNotEmpty()) {
            muxer.start()
            started = true
            for ((isVideo, buffer, info) in pending) {
                if (isVideo) muxer.writeSampleData(videoTrack, buffer, info)
            }
            pending.clear()
        }
        val written = started && runCatching { muxer.stop() }.isSuccess
        runCatching { muxer.release() }
        return written
    }
}
