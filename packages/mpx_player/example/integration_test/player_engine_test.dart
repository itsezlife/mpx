import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_core/mpx_core.dart';
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

    Future<PlayerEngine> ready([MediaKey key = LocalMedia.clip]) async {
      final engine = media.backend.create(key)..prepare();
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

    Future<PlayerEngine> playingStream() async {
      final engine = await ready(LocalMedia.stream);
      engine.play();
      await until(engine, () => engine.position > const Duration(seconds: 1));
      return engine;
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

    // Android plays the HLS stream; Apple players open progressive files
    // only and play the MP4 fallback.
    testWidgets('the stream plays, seeks and loops', (_) async {
      final engine = await ready(LocalMedia.stream);
      engine
        ..setLooping(looping: true)
        ..play();
      await until(engine, () => engine.position > const Duration(seconds: 1));
      expect(engine.state.value.firstFrameRendered, isTrue);
      expect(engine.state.value.videoSize?.width, 256);

      engine.seekTo(const Duration(seconds: 9));
      await until(engine, () => engine.position > const Duration(seconds: 9));
      await until(
        engine,
        () =>
            engine.state.value.phase == PlayerPhase.ready &&
            engine.position < const Duration(seconds: 3) &&
            engine.position > Duration.zero,
      );
      expect(engine.state.value.playing, isTrue);
    });

    testWidgets(
      'a stream played once replays from the cache with the origin gone',
      (_) async {
        (await playingStream()).dispose();
        final asked = media.originRequests.length;
        media.originOnline = false;
        addTearDown(() => media.originOnline = true);

        await playingStream();
        expect(media.originRequests, hasLength(asked));
      },
      skip: !Platform.isAndroid,
    );

    testWidgets('the probe lists the decoders and containers', (_) async {
      final device = await media.backend.device;

      expect(device.canDecode('video/avc'), isTrue);
      expect(device.opensContainer('video/mp4'), isTrue);
      // Media3 opens WebM; Apple's players do not.
      expect(device.opensContainer('video/webm'), Platform.isAndroid);
      // MediaCodec reports how many decoders may run; Apple's do not.
      expect(device.instanceCountsKnown, Platform.isAndroid);
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
