package dev.mpx.player

import android.content.Context
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.view.TextureRegistry

/**
 * The platform side of `NativePlayerBackend`: one [MpxVideoPlayer] per
 * player id, driven over the Pigeon channel ([PlayerHostApi]) and reporting
 * back through [PlayerFlutterApi].
 */
@UnstableApi
class MpxPlayerPlugin : FlutterPlugin, PlayerHostApi {
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private lateinit var flutter: PlayerFlutterApi
    private lateinit var focus: MpxAudioFocus
    private val players = HashMap<Long, MpxVideoPlayer>()
    private var nextId = 1L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        flutter = PlayerFlutterApi(binding.binaryMessenger)
        // Focus callbacks and the noisy broadcast arrive on the main thread,
        // where Pigeon's Flutter API must be called.
        focus = MpxAudioFocus(context) { change -> flutter.onAudioFocusChange(change) {} }
        PlayerHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PlayerHostApi.setUp(binding.binaryMessenger, null)
        reset()
        focus.abandon()
    }

    // --- Players -----------------------------------------------------------

    override fun reset() {
        players.values.forEach { it.dispose() }
        players.clear()
        // A previous isolate's focus goes with its players.
        focus.abandon()
    }

    override fun create(source: NativePlayerSource, settings: NativePlayerSettings): Long {
        val version = HbcNative.version(source.readerApi)
        check(version == HbcNative.expectedVersion()) {
            "The bytes cache's native reader speaks version $version; " +
                "this player expects ${HbcNative.expectedVersion()}."
        }
        val id = nextId++
        players[id] =
            MpxVideoPlayer(
                context = context,
                id = id,
                source = source,
                settings = settings,
                producer = textures.createSurfaceProducer(),
                renderers = MpxRenderersFactory(context),
                report = { snapshot -> flutter.onSnapshot(snapshot) {} },
                failedCodecOf = { null },
            )
        return id
    }

    override fun play(playerId: Long) {
        players[playerId]?.play()
    }

    override fun pause(playerId: Long) {
        players[playerId]?.pause()
    }

    override fun seekTo(playerId: Long, positionUs: Long, seekId: Long) {
        players[playerId]?.seekTo(positionUs, seekId)
    }

    override fun setSpeed(playerId: Long, speed: Double) {
        players[playerId]?.setSpeed(speed)
    }

    override fun setLooping(playerId: Long, looping: Boolean) {
        players[playerId]?.setLooping(looping)
    }

    override fun setVolume(playerId: Long, volume: Double) {
        players[playerId]?.setVolume(volume)
    }

    override fun dispose(playerId: Long) {
        players.remove(playerId)?.dispose()
    }

    // --- Audio focus (ticket 26) ---------------------------------------------

    override fun requestAudioFocus() = focus.request()

    override fun abandonAudioFocus() = focus.abandon()

    // --- Hardware probe (ticket 28) ------------------------------------------

    override fun probe(): NativeDeviceProbe =
        NativeDeviceProbe(
            lowRam = false,
            totalMemoryBytes = 0,
            cpuCount = Runtime.getRuntime().availableProcessors().toLong(),
            memoryClassMb = 0,
            decoders = emptyList(),
            containers = emptyList(),
            failedCodecs = emptyList(),
        )

    // --- Picture in picture and background audio (ticket 29) -----------------

    override fun isPictureInPictureSupported(): Boolean = false

    override fun startPictureInPicture(playerId: Long) {}

    override fun stopPictureInPicture() {}

    override fun setBackgroundAudio(enabled: Boolean) {}
}
