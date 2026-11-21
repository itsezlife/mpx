package dev.mpx.capture

import android.annotation.SuppressLint
import android.graphics.SurfaceTexture
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import androidx.camera.core.SurfaceRequest
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor
import kotlin.math.abs

/**
 * The camera's frames on their way to the screen and, while a recording
 * runs, to the encoder: CameraX draws into a SurfaceTexture of this pipe,
 * and its GL thread draws each frame into the Flutter surface and into the
 * video encoder's input surface. Recording never changes the camera's
 * session: no use case joins or leaves, so the preview never stalls.
 *
 * The frames go out as a SurfaceTexture consumer would show them (through
 * its transform matrix); what turn is left for upright the session reports
 * to Dart, and a recording carries it as its orientation hint.
 */
internal class CameraPipe(
    private val producer: TextureRegistry.SurfaceProducer,
    private val onSize: (width: Int, height: Int) -> Unit,
    // Which axis of the drawn frame to flip: 0 none, 1 across (x), 2 down
    // (y). A front camera's frames arrive mirrored; flipped back here, the
    // frames are the scene as it is (what a recording keeps), and the
    // preview mirrors them itself.
    private val unmirror: () -> Int = { 0 },
) {
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("mpx-camera-gl").apply { start() }
    private val gl = Handler(thread.looper)

    /** Runs on the GL thread. */
    val executor = Executor { gl.post(it) }

    // GL thread state.
    private var stage: GlStage? = null
    private var previewSurface: EGLSurface? = null
    private var target: SurfaceTexture? = null
    private var texture = 0
    private var width = 0
    private var height = 0
    private val matrix = FloatArray(16)
    private var recording: Recording? = null
    private var released = false

    private fun stage(): GlStage = stage ?: GlStage().also { stage = it }

    // --- Camera (CameraX's request, on the GL thread) ---

    /**
     * Gives the camera a surface of this pipe. [matrixTurns] quarter turns
     * of the frame are in the SurfaceTexture's matrix (a camera that writes
     * its orientation into the buffer): the drawn frame's sides swap then.
     */
    fun provide(request: SurfaceRequest, matrixTurns: () -> Int) {
        if (released) {
            request.willNotProvideSurface()
            return
        }
        val stage = stage()
        val name = stage.externalTexture()
        val surfaceTexture = SurfaceTexture(name).apply {
            setDefaultBufferSize(request.resolution.width, request.resolution.height)
            setOnFrameAvailableListener({ onFrame(it) }, gl)
        }
        val surface = Surface(surfaceTexture)
        request.provideSurface(surface, executor) {
            surface.release()
            surfaceTexture.release()
            if (!released) stage.deleteTexture(name)
            if (target === surfaceTexture) target = null
        }
        target = surfaceTexture
        texture = name
        bufferWidth = request.resolution.width
        bufferHeight = request.resolution.height
        this.matrixTurns = matrixTurns
        sized = false
        attachPreview()
    }

    private var bufferWidth = 0
    private var bufferHeight = 0
    private var matrixTurns: () -> Int = { 0 }

    // The drawn frame's size is settled at the first frame, once the
    // camera's transformation is known.
    private var sized = false

    private fun size() {
        val turned = matrixTurns() % 2 != 0
        val w = if (turned) bufferHeight else bufferWidth
        val h = if (turned) bufferWidth else bufferHeight
        sized = true
        if (w == width && h == height) return
        width = w
        height = h
        main.post {
            producer.setSize(w, h)
            onSize(w, h)
            // A resized producer may hand out a new surface.
            attachPreview()
        }
    }

    /** The Flutter surface came (back): draw into it. */
    fun attachPreview() = gl.post {
        if (released) return@post
        detach()
        previewSurface = runCatching { stage().windowSurface(producer.surface) }.getOrNull()
    }

    /** The Flutter surface goes. */
    fun detachPreview() = gl.post { detach() }

    private fun detach() {
        previewSurface?.let { stage?.releaseSurface(it) }
        previewSurface = null
    }

    private fun onFrame(surfaceTexture: SurfaceTexture) {
        if (released || surfaceTexture !== target) return
        if (!sized) size()
        surfaceTexture.updateTexImage()
        surfaceTexture.getTransformMatrix(matrix)
        when (unmirror()) {
            1 -> android.opengl.Matrix.multiplyMM(matrix, 0, matrix.copyOf(), 0, FLIP_U, 0)
            2 -> android.opengl.Matrix.multiplyMM(matrix, 0, matrix.copyOf(), 0, FLIP_V, 0)
        }
        val stage = stage ?: return
        previewSurface?.let {
            runCatching { stage.drawWhole(it, width, height, texture, matrix) }
        }
        recording?.frame(surfaceTexture.timestamp)
    }

    // --- Recording ---

    /**
     * Starts recording the frames into [path] (H.264 at the preview's size,
     * [bitrate] bits a second, and AAC from the microphone with [audio]);
     * [turn] degrees turn it upright. [done] runs on the main thread.
     */
    fun startRecording(
        path: String,
        bitrate: Int,
        audio: Boolean,
        turn: Int,
        done: (Result<Unit>) -> Unit,
    ) = gl.post {
        if (recording != null) {
            main.post { done(Result.failure(CaptureException.failed("already recording"))) }
            return@post
        }
        if (width == 0) {
            main.post { done(Result.failure(CaptureException.failed("camera not available"))) }
            return@post
        }
        val result = runCatching {
            recording = Recording(path, width and 1.inv(), height and 1.inv(), bitrate, audio, turn)
        }
        main.post { done(result) }
    }

    /** Ends the recording; [done] gets its facts on the main thread. */
    fun stopRecording(done: (Result<Pair<String, Long>>) -> Unit) = gl.post {
        val current = recording
        recording = null
        if (current == null) {
            main.post { done(Result.failure(CaptureException.failed("not recording"))) }
            return@post
        }
        val result = runCatching { current.finish() }
        main.post { done(result) }
    }

    fun release() = gl.post {
        released = true
        recording?.cancel()
        recording = null
        detach()
        target = null
        stage?.release()
        stage = null
        thread.quitSafely()
    }

    /** One recording: an encoder fed by the GL thread, a microphone pump. */
    private inner class Recording(
        private val path: String,
        private val width: Int,
        private val height: Int,
        bitrate: Int,
        audio: Boolean,
        turn: Int,
    ) {
        private val writer: Mp4Writer
        private val encoder: MediaCodec
        private val encoderSurface: EGLSurface
        private val pump: AudioPump?
        @Volatile private var startNs = -1L
        @Volatile private var clock: () -> Long = System::nanoTime
        private var lastNs = 0L

        init {
            File(path).delete()
            writer = Mp4Writer(path, turn)
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = stage().windowSurface(encoder.createInputSurface())
            encoder.start()
            pump = if (audio) runCatching { AudioPump().also { it.start() } }.getOrNull() else null
        }

        fun frame(frameNs: Long) {
            if (startNs < 0) {
                clock = clockOf(frameNs)
                startNs = frameNs
            }
            val ptsNs = frameNs - startNs
            if (ptsNs < 0) return
            lastNs = ptsNs
            stage?.drawWhole(encoderSurface, width, height, texture, matrix, ptsNs)
            drain(encoder, video = true, endOfStream = false)
        }

        /** The file and its length in microseconds. */
        fun finish(): Pair<String, Long> {
            encoder.signalEndOfInputStream()
            drain(encoder, video = true, endOfStream = true)
            pump?.finish()
            val written = writer.finish()
            close()
            if (!written) {
                File(path).delete()
                throw CaptureException.failed("nothing was recorded")
            }
            return path to lastNs / 1000
        }

        fun cancel() {
            pump?.cancel()
            writer.finish()
            close()
            File(path).delete()
        }

        private fun close() {
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
            stage?.releaseSurface(encoderSurface)
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

        /** Microphone PCM into an AAC encoder (32 kbit/s, 48 kHz mono). */
        private inner class AudioPump {
            private val sampleRate = 48_000
            private val chunk = 2048
            private val codec: MediaCodec
            private val record: AudioRecord
            private val worker = Thread(::run, "mpx-camera-audio")
            @Volatile private var ending = false
            @Volatile private var aborted = false
            private var lastPtsUs = -1L

            init {
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 32_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, chunk * 2)
                }
                codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                val minimum = AudioRecord.getMinBufferSize(
                    sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                )
                record = newRecord(maxOf(minimum, chunk * 4))
            }

            @SuppressLint("MissingPermission") // The session checks it.
            private fun newRecord(size: Int) = AudioRecord(
                MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, size,
            )

            fun start() {
                codec.start()
                record.startRecording()
                worker.start()
            }

            fun finish() {
                ending = true
                worker.join(3000)
            }

            fun cancel() {
                aborted = true
                ending = true
                worker.join(1000)
            }

            private fun run() {
                val pcm = ByteArray(chunk)
                try {
                    while (!ending) {
                        val read = record.read(pcm, 0, chunk)
                        if (read <= 0) continue
                        val nowNs = clock()
                        if (startNs < 0) continue
                        val durationUs = read / 2 * 1_000_000L / sampleRate
                        var ptsUs = (nowNs - startNs) / 1000 - durationUs
                        if (ptsUs < 0) continue
                        if (ptsUs <= lastPtsUs) ptsUs = lastPtsUs + 1
                        lastPtsUs = ptsUs
                        queue(pcm, read, ptsUs, 0)
                        drain(codec, video = false, endOfStream = false)
                    }
                    if (!aborted) {
                        queue(ByteArray(0), 0, maxOf(lastPtsUs + 1, 0), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        drain(codec, video = false, endOfStream = true)
                    }
                } catch (error: Exception) {
                    // A failing microphone ends the audio track; the video goes on.
                } finally {
                    runCatching { record.stop() }
                    record.release()
                    runCatching { codec.stop() }
                    codec.release()
                }
            }

            private fun queue(pcm: ByteArray, size: Int, ptsUs: Long, flags: Int) {
                val index = codec.dequeueInputBuffer(10_000)
                if (index < 0) return
                val input = codec.getInputBuffer(index) ?: return
                input.clear()
                input.put(pcm, 0, size)
                codec.queueInputBuffer(index, 0, size, ptsUs, flags)
            }
        }
    }

    private companion object {
        // Texture-coordinate flips about the centre (column-major).
        val FLIP_U = floatArrayOf(-1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 0f, 0f, 1f)
        val FLIP_V = floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)

        // A frame's timestamp is close to now on its own clock (monotonic or
        // boot time, by device); the microphone's samples are timed on it.
        fun clockOf(frameNs: Long): () -> Long {
            val monotonic = System.nanoTime()
            val boot = SystemClock.elapsedRealtimeNanos()
            return if (abs(frameNs - boot) < abs(frameNs - monotonic)) {
                SystemClock::elapsedRealtimeNanos
            } else {
                System::nanoTime
            }
        }
    }
}
