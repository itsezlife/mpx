import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';
import 'package:mpx_player/src/native/player_messages.g.dart';
import 'package:mpx_player/testing.dart';

import 'simulated_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const clip = MediaKey.remote('clip');
  const broken = MediaKey.remote('broken');

  late SimulatedHost host;
  late NativePlayerBackend backend;
  late List<String> published;
  late List<String> withdrawn;

  PlayerSource sourceOf(String name, {String? codec}) => PlayerSource(
    RangedRequest(
      url: Uri.parse('https://media.example/$name'),
      cacheKey: BytesCacheKey(name),
    ),
    codec: codec,
  );

  NativePlayerBackend backendOver(
    SimulatedHost simulated, {
    Map<MediaKey, List<PlayerSource>>? sources,
    bool backgroundAudio = false,
  }) {
    host = simulated;
    final made = NativePlayerBackend.over(
      host: simulated,
      publish: (request) async {
        published.add(request.cacheKey.value);
        return () async => withdrawn.add(request.cacheKey.value);
      },
      readerApi: 0x1000,
      sourcesOf: (key) =>
          sources?[key] ??
          [
            sourceOf(switch (key) {
              MediaKey$Remote(:final id) => id,
              _ => 'other',
            }),
          ],
      backgroundAudio: backgroundAudio,
      receive: false,
    );
    simulated.receiver = made.receiver;
    return made;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    published = [];
    withdrawn = [];
  });

  group('NativePlayerBackend over a simulated platform', () {
    PlayerEngineContract.run(() {
      backend = backendOver(SimulatedHost(unplayable: {'broken'}));
      addTearDown(backend.dispose);
      return PlayerEngineHarness(
        backend: backend,
        playable: clip,
        unplayable: broken,
        settle: settle,
      );
    });
  });

  group('NativePlayerBackend', () {
    setUp(() => backend = backendOver(SimulatedHost()));
    tearDown(() => backend.dispose());

    Future<PlayerEngine> ready(PlayerEngine engine) async {
      for (var i = 0; i < 20; i++) {
        if (engine.state.value.phase == PlayerPhase.ready) return engine;
        await settle();
      }
      fail('never ready: ${engine.state.value}');
    }

    test('publishes the source and withdraws it on dispose', () async {
      final engine = await ready(backend.create(clip)..prepare());

      expect(published, ['clip']);
      expect(host.calls, contains('create clip'));

      engine.dispose();
      await settle();
      await settle();

      expect(host.live, isEmpty);
      expect(withdrawn, ['clip']);
    });

    test('wishes made while the platform creates are caught up', () async {
      final gate = host.createGate = Completer<void>();
      final engine = backend.create(clip)..prepare();
      await settle();
      engine
        ..play()
        ..setSpeed(2)
        ..setVolume(0.5)
        ..setLooping(looping: true)
        ..seekTo(const Duration(seconds: 7));
      gate.complete();
      await ready(engine);

      final player = host.live.single;
      expect(player.playing, isTrue);
      expect(player.speed, 2);
      expect(player.volume, 0.5);
      expect(player.looping, isTrue);
      expect(player.positionUs, 7000000);
      // It plays from there.
      expect(engine.position, greaterThanOrEqualTo(const Duration(seconds: 7)));
      expect(engine.position, lessThan(const Duration(seconds: 8)));
    });

    test(
      'disposing while the platform creates disposes what it made',
      () async {
        final gate = host.createGate = Completer<void>();
        final engine = backend.create(clip)..prepare();
        await settle();
        engine.dispose();
        gate.complete();
        await settle();
        await settle();

        expect(host.live, isEmpty);
        expect(withdrawn, ['clip']);
      },
    );

    test('the playhead moves between reports at the speed set', () async {
      final engine = await ready(backend.create(clip)..prepare());
      engine
        ..setSpeed(2)
        ..play();
      await settle();
      final before = engine.position;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        engine.position - before,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
      engine.pause();
      final paused = engine.position;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.position, paused);
    });

    test('a seek reads at its target until the platform reports it', () async {
      final engine = await ready(backend.create(clip)..prepare());
      host.live.single.disposed = true; // stops reporting
      engine.seekTo(const Duration(seconds: 5));

      expect(engine.position, const Duration(seconds: 5));
    });
  });

  group('decoder failure', () {
    test('a codec whose decoder fails moves to the next source', () async {
      backend = backendOver(
        SimulatedHost(
          brokenCodecs: {'video/av01'},
          codecOf: {'clip-av1': 'video/av01', 'clip-avc': 'video/avc'},
        ),
        sources: {
          clip: [
            sourceOf('clip-av1', codec: 'video/av01'),
            sourceOf('clip-avc', codec: 'video/avc'),
          ],
        },
      );
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 20; i++) {
        await settle();
      }

      expect(engine.state.value.phase, PlayerPhase.ready);
      expect(published, ['clip-av1', 'clip-avc']);
      expect(withdrawn, ['clip-av1']);

      // The next engine skips the codec that failed here.
      final next = backend.create(clip)..prepare();
      for (var i = 0; i < 20; i++) {
        await settle();
      }
      expect(next.state.value.phase, PlayerPhase.ready);
      expect(published.last, 'clip-avc');
      expect(published.where((key) => key == 'clip-av1'), hasLength(1));
    });

    test('a codec the probe says failed before is skipped', () async {
      backend = backendOver(
        SimulatedHost(
          probeResult: NativeDeviceProbe(
            lowRam: false,
            totalMemoryBytes: 0,
            cpuCount: 0,
            memoryClassMb: 0,
            decoders: [],
            containers: [],
            failedCodecs: ['video/av01'],
          ),
        ),
        sources: {
          clip: [
            sourceOf('clip-av1', codec: 'video/av01'),
            sourceOf('clip-avc', codec: 'video/avc'),
          ],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      expect(published, ['clip-avc']);
    });

    test('a container the platform does not open is skipped', () async {
      backend = backendOver(
        SimulatedHost(
          probeResult: NativeDeviceProbe(
            lowRam: false,
            totalMemoryBytes: 0,
            cpuCount: 0,
            memoryClassMb: 0,
            decoders: [],
            containers: ['video/mp4'],
            failedCodecs: [],
          ),
        ),
        sources: {
          clip: [
            PlayerSource(
              RangedRequest(
                url: Uri.parse('https://media.example/clip.webm'),
                cacheKey: const BytesCacheKey('clip-webm'),
              ),
              mimeType: 'video/webm',
            ),
            sourceOf('clip-mp4'),
          ],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      expect(published, ['clip-mp4']);
    });

    test('no playable source fails the engine', () async {
      backend = backendOver(SimulatedHost(), sources: {clip: []});
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      expect(engine.state.value.phase, PlayerPhase.failed);
      expect(engine.state.value.error, isNotNull);
    });
  });

  group('the platform session', () {
    setUp(() => backend = backendOver(SimulatedHost()));
    tearDown(() => backend.dispose());

    AudioFocusContract.run(() => backend.audioFocus);

    test('focus changes arrive as AudioFocusChange', () async {
      final heard = <AudioFocusChange>[];
      final listening = backend.audioFocus.changes.listen(heard.add);
      host.receiver
        ..onAudioFocusChange(NativeAudioFocusChange.interrupted)
        ..onAudioFocusChange(NativeAudioFocusChange.gained)
        ..onAudioFocusChange(NativeAudioFocusChange.outputRemoved)
        ..onAudioFocusChange(NativeAudioFocusChange.lost);
      await settle();
      await listening.cancel();

      expect(heard, [
        AudioFocusChange.interrupted,
        AudioFocusChange.gained,
        AudioFocusChange.outputRemoved,
        AudioFocusChange.lost,
      ]);
    });

    test('requests and abandons reach the platform', () async {
      backend.audioFocus
        ..request()
        ..abandon();
      await settle();

      expect(
        host.calls,
        containsAllInOrder(['requestAudioFocus', 'abandonAudioFocus']),
      );
    });

    test('picture in picture follows the platform', () async {
      await settle();
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }
      expect(backend.pictureInPicture.isSupported, isTrue);

      backend.pictureInPicture.start(engine);
      await settle();
      expect(backend.pictureInPicture.active.value, engine);

      backend.pictureInPicture.stop();
      await settle();
      expect(backend.pictureInPicture.active.value, isNull);
    });

    test('the probe becomes the device', () async {
      final device = await backend.device;

      expect(device.isHighClass, isTrue);
      expect(device.instanceCountsKnown, isFalse);
    });

    test('going to the background pauses players', () async {
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }
      engine.play();
      await settle();

      final binding = TestWidgetsFlutterBinding.instance;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      addTearDown(
        () => binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      await settle();

      expect(engine.state.value.playing, isFalse);
      expect(host.live.single.playing, isFalse);
    });

    test('with background audio, players keep playing', () async {
      backend.dispose();
      backend = backendOver(SimulatedHost(), backgroundAudio: true);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }
      engine.play();
      await settle();

      final binding = TestWidgetsFlutterBinding.instance;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      addTearDown(
        () => binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      await settle();

      expect(engine.state.value.playing, isTrue);
      expect(host.backgroundAudio, isTrue);
    });
  });
}
