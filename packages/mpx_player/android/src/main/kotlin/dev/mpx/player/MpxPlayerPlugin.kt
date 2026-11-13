package dev.mpx.player

import android.content.Context
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.view.TextureRegistry

/**
 * The platform side of `NativePlayerBackend`: one [MpxVideoPlayer] per
 * player id, driven over the Pigeon channel ([PlayerHostApi]) and reporting
 * back through [PlayerFlutterApi].
 */
@UnstableApi
class MpxPlayerPlugin : FlutterPlugin, ActivityAware, PlayerHostApi {
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private lateinit var flutter: PlayerFlutterApi
    private lateinit var focus: MpxAudioFocus
    private lateinit var device: MpxDeviceProbe
    private lateinit var pictureInPicture: MpxPictureInPicture
    private lateinit var background: MpxBackgroundAudio
    private lateinit var parts: StreamParts
    private val players = HashMap<Long, MpxVideoPlayer>()
    private var nextId = 1L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        flutter = PlayerFlutterApi(binding.binaryMessenger)
        parts = StreamParts(flutter)
        device = MpxDeviceProbe(context)
        pictureInPicture =
            MpxPictureInPicture { id, active -> flutter.onPictureInPictureChange(id, active) {} }
        background = MpxBackgroundAudio(context)
        // Focus callbacks and the noisy broadcast arrive on the main thread,
        // where Pigeon's Flutter API must be called.
        focus = MpxAudioFocus(context) { change -> flutter.onAudioFocusChange(change) {} }
        PlayerHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PlayerHostApi.setUp(binding.binaryMessenger, null)
        reset()
        focus.abandon()
        background.enabled = false
    }

    // --- Activity ----------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) =
        pictureInPicture.attach(binding.activity)

    override fun onDetachedFromActivityForConfigChanges() = pictureInPicture.detach()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        pictureInPicture.attach(binding.activity)

    override fun onDetachedFromActivity() = pictureInPicture.detach()

    // --- Players -----------------------------------------------------------

    override fun reset() {
        players.values.forEach { release(it) }
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
                parts = parts,
                report = { snapshot ->
                    flutter.onSnapshot(snapshot) {}
                    background.update(players.values.firstOrNull { it.isAudible }?.player)
                },
                failedCodecOf = device::failedCodecOf,
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
        players.remove(playerId)?.let { release(it) }
    }

    private fun release(player: MpxVideoPlayer) {
        pictureInPicture.forget(player.id)
        background.forget(player.player)
        player.dispose()
    }

    // --- Audio focus --------------------------------------------------------

    override fun requestAudioFocus() = focus.request()

    override fun abandonAudioFocus() = focus.abandon()

    // --- Hardware probe -----------------------------------------------------

    override fun probe(): NativeDeviceProbe = device.probe()

    // --- Picture in picture and background audio ----------------------------

    override fun isPictureInPictureSupported(): Boolean = pictureInPicture.isSupported

    override fun startPictureInPicture(playerId: Long) {
        val player = players[playerId] ?: return
        pictureInPicture.start(playerId, player.aspectRatio)
    }

    override fun stopPictureInPicture() = pictureInPicture.stop()

    override fun setBackgroundAudio(enabled: Boolean) {
        background.enabled = enabled
        if (enabled) background.update(players.values.firstOrNull { it.isAudible }?.player)
    }
}
