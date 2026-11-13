import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_player_example/local_media.dart';

/// The PlayerEngine contract on the platform's own player, reading the clip
/// through the bytes cache's native reader from a loopback origin.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalMedia media;

  setUpAll(() async => media = await LocalMedia.start());
  tearDownAll(() => media.close());

  group('NativePlayerBackend', () {
    PlayerEngineContract.run(
      () => PlayerEngineHarness(
        backend: media.backend,
        playable: LocalMedia.clip,
        unplayable: LocalMedia.garbage,
        settle: () => Future<void>.delayed(const Duration(milliseconds: 50)),
      ),
    );

    AudioFocusContract.run(() => media.backend.audioFocus);

    PictureInPictureContract.run(() => media.backend.pictureInPicture);

    Future<PlayerEngine> ready() async {
      final engine = media.backend.create(LocalMedia.clip)..prepare();
      addTearDown(engine.dispose);
      for (var i = 0; i < 200; i++) {
        if (engine.state.value.phase == PlayerPhase.ready) return engine;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('never ready: ${engine.state.value}');
    }

    Future<void> until(PlayerEngine engine, bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        if (done()) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('never happened: ${engine.state.value} at ${engine.position}');
    }

    testWidgets('plays: the playhead moves and frames arrive', (_) async {
      final engine = await ready();
      engine.play();
      await until(engine, () => engine.position > const Duration(seconds: 1));

      expect(engine.state.value.firstFrameRendered, isTrue);
      expect(engine.state.value.videoSize?.width, 256);
      expect(engine.state.value.phase, PlayerPhase.ready);
    });

    testWidgets('a pass that does not loop ends at the end', (_) async {
      final engine = await ready();
      engine
        ..seekTo(const Duration(seconds: 11))
        ..play();
      await until(engine, () => engine.state.value.phase == PlayerPhase.ended);

      expect(engine.position, engine.state.value.duration);
    });

    testWidgets('a looping pass starts again', (_) async {
      final engine = await ready();
      engine
        ..setLooping(looping: true)
        ..seekTo(const Duration(milliseconds: 11500))
        ..play();
      await until(
        engine,
        () =>
            engine.state.value.phase == PlayerPhase.ready &&
            engine.position < const Duration(seconds: 2) &&
            engine.position > Duration.zero,
      );

      expect(engine.state.value.playing, isTrue);
    });

    testWidgets('playing at the end starts from the beginning', (_) async {
      final engine = await ready();
      engine
        ..seekTo(const Duration(seconds: 11))
        ..play();
      await until(engine, () => engine.state.value.phase == PlayerPhase.ended);
      engine.play();
      await until(
        engine,
        () =>
            engine.state.value.phase == PlayerPhase.ready &&
            engine.position < const Duration(seconds: 3),
      );
    });

    testWidgets('the probe lists the decoders and containers', (_) async {
      final device = await media.backend.device;

      expect(device.canDecode('video/avc'), isTrue);
      expect(device.opensContainer('video/mp4'), isTrue);
      expect(device.opensContainer('video/webm'), isFalse);
      expect(device.instanceCountsKnown, isFalse);
    });

    testWidgets('picture in picture opens and closes', (_) async {
      final pip = media.backend.pictureInPicture;
      final engine = await ready();
      engine.play();
      await until(engine, () => engine.position > Duration.zero);
      expect(pip.isSupported, isTrue);

      pip.start(engine);
      await until(engine, () => pip.active.value == engine);
      pip.stop();
      await until(engine, () => pip.active.value == null);
    });
  });
}
