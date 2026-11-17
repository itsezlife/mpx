import 'dart:async';
import 'dart:typed_data';

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
  late List<BytesRequest> playlistRequests;

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
    Stopwatch? clock,
    void Function()? Function(void Function() check)? watchdog,
    PreparedBuffer preparedBuffer = PreparedBuffer.standard,
  }) {
    host = simulated;
    final made = NativePlayerBackend.over(
      host: simulated,
      publish: (request) async {
        published.add(request.cacheKey.value);
        return () async => withdrawn.add(request.cacheKey.value);
      },
      readerApi: 0x1000,
      loadPlaylist: (request) async {
        playlistRequests.add(request);
        return Uint8List.fromList('#EXTM3U'.codeUnits);
      },
      sourcesOf: (key) =>
          sources?[key] ??
          [
            sourceOf(switch (key) {
              MediaKey$Remote(:final id) => id,
              _ => 'other',
            }),
          ],
      backgroundAudio: backgroundAudio,
      preparedBuffer: preparedBuffer,
      receive: false,
      clock: clock,
      startWatchdog: watchdog == null
          ? null
          : (check) {
              watchdog(check);
              return _NoTimer();
            },
    );
    simulated.receiver = made.receiver;
    return made;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    published = [];
    withdrawn = [];
    playlistRequests = [];
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

    test('a player is created with the prepared buffer: about 2 s and '
        '2 MiB ahead until it first plays', () async {
      await ready(backend.create(clip)..prepare());

      final settings = host.live.single.settings;
      expect(settings.preparedBufferMs, 2000);
      expect(settings.preparedBufferBytes, 2 * 1024 * 1024);
    });

    test('a backend without the cap lets every player buffer as it '
        'would', () async {
      final uncapped = backendOver(
        SimulatedHost(),
        preparedBuffer: PreparedBuffer.none,
      );
      addTearDown(uncapped.dispose);

      await ready(uncapped.create(clip)..prepare());

      expect(host.live.single.settings.preparedBufferMs, 0);
      expect(host.live.single.settings.preparedBufferBytes, 0);
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

  group('the playhead between reports', () {
    late _ManualClock clock;

    setUp(() {
      clock = _ManualClock();
      backend = backendOver(
        SimulatedHost()..now = () => clock.elapsedMicroseconds,
        clock: clock,
      );
    });
    tearDown(() => backend.dispose());

    Future<PlayerEngine> playing({double speed = 1}) async {
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 20; i++) {
        if (engine.state.value.phase == PlayerPhase.ready) break;
        await settle();
      }
      engine
        ..setSpeed(speed)
        ..play();
      await settle();
      return engine;
    }

    // Runs 3 s of 60 Hz frames over [engine], the platform reporting every
    // 500 ms a position that runs at [drift] times the speed set (a player
    // behind or ahead of the clock); returns the playhead of every frame and
    // the platform's position at it.
    Future<List<(Duration, Duration)>> run(
      PlayerEngine engine, {
      required double speed,
      required double drift,
    }) async {
      final player = host.live.single;
      final start = player.positionUs;
      final frames = <(Duration, Duration)>[];
      for (var frame = 1; frame <= 180; frame++) {
        clock.advance(const Duration(microseconds: 16667));
        final wallUs = clock.elapsed.inMicroseconds;
        final platformUs = start + (wallUs * speed * drift).round();
        if (frame % 30 == 0) {
          player
            ..positionUs = platformUs
            ..report();
          await settle();
        }
        frames.add((engine.position, Duration(microseconds: platformUs)));
      }
      return frames;
    }

    for (final speed in [0.5, 1.0, 2.0]) {
      for (final drift in [0.9, 1.1]) {
        test('at ${speed}x, against a platform ${drift}x the clock, it never '
            'steps back and stays near the platform', () async {
          final engine = await playing(speed: speed);
          final frames = await run(engine, speed: speed, drift: drift);

          for (var i = 1; i < frames.length; i++) {
            expect(
              frames[i].$1,
              greaterThanOrEqualTo(frames[i - 1].$1),
              reason: 'frame $i',
            );
            // No frame jumps more than a frame and a half at twice the speed.
            expect(
              frames[i].$1 - frames[i - 1].$1,
              lessThanOrEqualTo(
                Duration(microseconds: (16667 * speed * 3).round()),
              ),
              reason: 'frame $i',
            );
          }
          for (final (shown, platform) in frames.skip(30)) {
            expect(
              (shown - platform).abs(),
              lessThan(Duration(milliseconds: (100 * speed).round() + 20)),
            );
          }
        });
      }
    }

    // A platform that takes a speed change [lateMs] after it was asked for
    // (a player whose audio pipeline runs at the old speed a while), at
    // [from]x then [to]x: 1 s, the change, 2 s more, reporting every 100 ms.
    // Returns the playhead of every 60 Hz frame and the platform's position.
    Future<List<(Duration, Duration)>> change(
      PlayerEngine engine, {
      required double from,
      required double to,
      required int lateMs,
    }) async {
      final player = host.live.single;
      var platformUs = player.positionUs.toDouble();
      var rate = from;
      Duration? changedAt;
      final frames = <(Duration, Duration)>[];
      for (var frame = 1; frame <= 180; frame++) {
        clock.advance(const Duration(microseconds: 16667));
        // The frame that just passed played at the rate before this one.
        platformUs += 16667 * rate;
        if (frame == 60) {
          engine.setSpeed(to);
          changedAt = clock.elapsed;
        }
        if (changedAt != null &&
            clock.elapsed - changedAt >= Duration(milliseconds: lateMs)) {
          rate = to;
        }
        player.positionUs = platformUs.round();
        if (frame % 6 == 0) {
          player.report();
          await settle();
        }
        frames.add((
          engine.position,
          Duration(microseconds: platformUs.round()),
        ));
      }
      return frames;
    }

    for (final (from, to) in [(2.0, 0.2), (0.2, 2.0), (1.0, 1.5)]) {
      for (final lateMs in [0, 500]) {
        test('${from}x to ${to}x, taken $lateMs ms late: it follows the '
            'player, never back, never by a step', () async {
          final engine = await playing(speed: from);
          final frames = await change(
            engine,
            from: from,
            to: to,
            lateMs: lateMs,
          );
          final fastest = from > to ? from : to;
          // A frame at twice the fastest rate, and a hair.
          final step = Duration(
            microseconds: (16667 * fastest * 2).round() + 500,
          );

          for (var i = 1; i < frames.length; i++) {
            final moved = frames[i].$1 - frames[i - 1].$1;
            expect(moved, greaterThanOrEqualTo(Duration.zero), reason: '$i');
            expect(moved, lessThanOrEqualTo(step), reason: 'frame $i');
          }
          // A player that takes the speed late is followed from the second
          // report after the change: off by what the two rates part by over
          // two report intervals at most, then back on course.
          final delta = (from - to).abs();
          final bound = lateMs == 0
              ? Duration(milliseconds: (20 * fastest).round() + 10)
              : Duration(
                  milliseconds: (200 * delta + 40 * fastest).round() + 25,
                );
          for (final (i, (shown, platform)) in frames.indexed.skip(12)) {
            expect((shown - platform).abs(), lessThan(bound), reason: '$i');
          }
          if (lateMs == 0) {
            // At the new rate within 150 ms of the change (frame 60).
            for (var i = 69; i < frames.length; i++) {
              final moved = frames[i].$1 - frames[i - 1].$1;
              expect(
                moved.inMicroseconds,
                closeTo(16667 * to, 16667 * to * 0.25 + 50),
                reason: 'frame $i',
              );
            }
          }
          // A player that took the speed at once is followed closely; one
          // that took it late leaves an error the playhead makes up gently.
          if (lateMs == 0) {
            for (final (shown, platform) in frames.skip(frames.length - 12)) {
              expect(
                (shown - platform).abs(),
                lessThan(Duration(milliseconds: (20 * fastest).round() + 5)),
                reason: 'settled',
              );
            }
          }
        });
      }
    }

    // Runs [engine] at [from]x for 1 s, then [to]x for 2 s, the platform
    // taking the change at once and its reports arriving 20 to 60 ms after
    // they were read (a busy main thread). Returns the playhead per frame.
    Future<List<Duration>> delayed(
      PlayerEngine engine, {
      required double from,
      required double to,
    }) async {
      final player = host.live.single;
      var platformUs = player.positionUs.toDouble();
      var rate = from;
      final frames = <Duration>[];
      for (var frame = 1; frame <= 180; frame++) {
        clock.advance(const Duration(microseconds: 16667));
        platformUs += 16667 * rate;
        if (frame == 60) {
          engine.setSpeed(to);
          rate = to;
        }
        if (frame % 6 == 0) {
          // Read some time ago, arriving now.
          final lateUs = 20000 + (frame * 7919) % 40000;
          player.positionUs = (platformUs - lateUs * rate).round();
          host.now = () => clock.elapsedMicroseconds - lateUs;
          player.report();
          await settle();
        }
        frames.add(engine.position);
      }
      return frames;
    }

    for (final (from, to) in [(2.0, 1.0), (2.0, 1.5), (1.0, 2.0)]) {
      test('${from}x to ${to}x with reports arriving late: no burst and no '
          'stall', () async {
        final engine = await playing(speed: from);
        final frames = await delayed(engine, from: from, to: to);

        for (var i = 13; i < frames.length; i++) {
          final rateNow = i < 60 ? from : to;
          final steady = 16667 * rateNow;
          final moved = (frames[i] - frames[i - 1]).inMicroseconds;
          expect(moved, greaterThan(0), reason: 'a stall at frame $i');
          expect(
            moved,
            lessThanOrEqualTo((steady * 1.3).round() + 1),
            reason: 'a burst at frame $i',
          );
        }
      });
    }

    test('speed changes (1x, 2x, 0.2x, 0.5x) never fail the engine on '
        'their own', () async {
      final engine = await playing();
      final player = host.live.single;
      var platformUs = player.positionUs.toDouble();
      var rate = 1.0;
      for (final (frame, speed) in [(30, 2.0), (90, 0.2), (150, 0.5)]) {
        while (clock.elapsed < Duration(microseconds: frame * 16667)) {
          clock.advance(const Duration(microseconds: 16667));
          platformUs += 16667 * rate;
          player.positionUs = platformUs.round();
          if (clock.elapsedMicroseconds ~/ 16667 % 6 == 0) {
            player.report();
            await settle();
          }
          expect(engine.position.isNegative, isFalse);
        }
        engine.setSpeed(speed);
        rate = speed;
        await settle();
      }
      engine.pause();
      await settle();

      expect(engine.state.value.phase, PlayerPhase.ready);
      expect(engine.state.value.error, isNull);
      expect(engine.state.value.speed, 0.5);
    });

    group('a player that stops without a word', () {
      late void Function() check;

      setUp(() {
        backend.dispose();
        backend = backendOver(
          SimulatedHost()..now = () => clock.elapsedMicroseconds,
          clock: clock,
          watchdog: (run) {
            check = run;
            return null;
          },
        );
      });

      test('reporting playing while its position stands still fails, saying '
          'so', () async {
        final engine = await playing();
        final player = host.live.single;
        for (var i = 0; i < 40; i++) {
          clock.advance(const Duration(milliseconds: 100));
          player.report();
          await settle();
          check();
        }

        expect(engine.state.value.phase, PlayerPhase.failed);
        expect(
          '${engine.state.value.error}',
          allOf(contains('stopped'), contains('$clip')),
        );
      });

      test('falling silent while it plays fails too', () async {
        final engine = await playing();
        clock.advance(const Duration(seconds: 4));
        check();

        expect(engine.state.value.phase, PlayerPhase.failed);
        expect('${engine.state.value.error}', contains('no report'));
      });

      test('a paused player, or one that moves, is left alone', () async {
        final engine = await playing();
        final player = host.live.single;
        for (var i = 0; i < 40; i++) {
          clock.advance(const Duration(milliseconds: 100));
          player
            ..positionUs += 100000
            ..report();
          await settle();
          check();
        }
        engine.pause();
        await settle();
        clock.advance(const Duration(seconds: 10));
        check();

        expect(engine.state.value.phase, PlayerPhase.ready);
      });
    });

    test('a seek still jumps, back as well', () async {
      final engine = await playing();
      clock.advance(const Duration(seconds: 3));
      host.live.single
        ..positionUs = 3000000
        ..report();
      await settle();

      engine.seekTo(const Duration(seconds: 1));
      await settle();

      expect(engine.position, const Duration(seconds: 1));
      clock.advance(const Duration(milliseconds: 100));
      expect(engine.position, const Duration(seconds: 1, milliseconds: 100));
    });

    test('a loop that wraps to the start jumps there', () async {
      final engine = await playing();
      engine.setLooping(looping: true);
      await settle();
      final player = host.live.single;
      clock.advance(const Duration(milliseconds: 100));
      player
        ..positionUs = SimulatedHost.durationUs - 50000
        ..report();
      await settle();
      clock.advance(const Duration(milliseconds: 100));
      player
        ..positionUs = 50000
        ..report();
      await settle();

      expect(engine.position, const Duration(milliseconds: 50));
    });

    test('a pause stops it where the platform says', () async {
      final engine = await playing();
      clock.advance(const Duration(seconds: 1));
      host.live.single
        ..positionUs = 900000
        ..playing = false
        ..report();
      await settle();

      expect(engine.position, const Duration(milliseconds: 900));
      clock.advance(const Duration(seconds: 1));
      expect(engine.position, const Duration(milliseconds: 900));
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
      expect(
        '${engine.state.value.error}',
        allOf(contains('No source'), contains('$clip')),
      );
    });

    test('a failure the platform reports says it came from the platform '
        'player, with its reason', () async {
      backend = backendOver(SimulatedHost(unplayable: {'clip'}));
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      expect(engine.state.value.phase, PlayerPhase.failed);
      expect(
        '${engine.state.value.error}',
        allOf(
          contains('platform player'),
          contains('$clip'),
          contains('cannot open'),
        ),
      );
    });

    test('a platform that cannot make a player fails the engine, saying '
        'so', () async {
      backend = backendOver(
        SimulatedHost()..createError = StateError('no surface'),
      );
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      expect(engine.state.value.phase, PlayerPhase.failed);
      expect(
        '${engine.state.value.error}',
        allOf(contains('Opening'), contains('$clip'), contains('no surface')),
      );
    });

    test('a decoder that fails on every source ends in a failure naming '
        'them', () async {
      backend = backendOver(
        SimulatedHost(
          codecOf: {'clip-a': 'avc', 'clip-b': 'hevc'},
          brokenCodecs: {'avc', 'hevc'},
        ),
        sources: {
          clip: [
            sourceOf('clip-a', codec: 'avc'),
            sourceOf('clip-b', codec: 'hevc'),
          ],
        },
      );
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 20; i++) {
        await settle();
      }

      expect(engine.state.value.phase, PlayerPhase.failed);
      expect(
        '${engine.state.value.error}',
        allOf(contains('No source'), contains('avc'), contains('hevc')),
      );
    });
  });

  group('HLS', () {
    const streamKey = BytesCacheKey('clip-hls');
    final master = Uri.parse('https://media.example/clip/master.m3u8');
    const segment = 'https://media.example/clip/720p/seg-1.ts';
    final hls = PlayerSource.hls(
      RangedRequest(
        url: master,
        cacheKey: streamKey,
        headers: const {'Authorization': 'Bearer t'},
      ),
    );

    Future<SimulatedPlayer> created() async {
      for (var i = 0; i < 20; i++) {
        if (host.live.isNotEmpty) return host.live.single;
        await settle();
      }
      fail('no platform player');
    }

    test('the platform player opens the playlist URL, nothing is published '
        'up front', () async {
      backend = backendOver(
        SimulatedHost(),
        sources: {
          clip: [hls],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();

      final player = await created();

      expect(player.source.playlistUrl, master.toString());
      expect(player.source.streamId, isNotNull);
      expect(published, isEmpty);
    });

    test('a playlist is resolved through the cache under the stream key, '
        'revalidated by HTTP rules', () async {
      backend = backendOver(
        SimulatedHost(),
        sources: {
          clip: [hls],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();
      final player = await created();

      final part = await host.receiver.openStreamPart(
        player.source.streamId!,
        master.toString(),
        true,
      );

      expect(String.fromCharCodes(part.bytes!), '#EXTM3U');
      expect(part.cacheKey, isNull);
      final request = playlistRequests.single;
      expect(request.url, master.toString());
      expect(request.cacheKey, BytesCacheKey.within(streamKey, '$master'));
      expect(request.revalidation, RevalidationPolicy.http);
      expect(request.headers, {'Authorization': 'Bearer t'});
      expect(published, isEmpty);
    });

    test('a segment is published under the stream key and withdrawn when the '
        'platform closes it', () async {
      backend = backendOver(
        SimulatedHost(),
        sources: {
          clip: [hls],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();
      final player = await created();
      final key = BytesCacheKey.within(streamKey, segment).value;

      final part = await host.receiver.openStreamPart(
        player.source.streamId!,
        segment,
        false,
      );

      expect(part.cacheKey, key);
      expect(part.bytes, isNull);
      expect(published, [key]);

      host.receiver.closeStreamPart(part.partId);
      await settle();
      expect(withdrawn, [key]);
    });

    test('disposing the engine withdraws the segments still open and refuses '
        'new parts', () async {
      backend = backendOver(
        SimulatedHost(),
        sources: {
          clip: [hls],
        },
      );
      addTearDown(backend.dispose);
      final engine = backend.create(clip)..prepare();
      final player = await created();
      final stream = player.source.streamId!;
      await host.receiver.openStreamPart(stream, segment, false);

      engine.dispose();
      await settle();
      await settle();

      expect(withdrawn, [BytesCacheKey.within(streamKey, segment).value]);
      await expectLater(
        host.receiver.openStreamPart(stream, segment, false),
        throwsStateError,
      );
    });

    test('a platform that opens progressive files only moves to the next '
        'source', () async {
      backend = backendOver(
        SimulatedHost(
          probeResult: NativeDeviceProbe(
            lowRam: false,
            totalMemoryBytes: 0,
            cpuCount: 0,
            memoryClassMb: 0,
            decoders: [],
            containers: ['video/mp4', 'video/quicktime'],
            failedCodecs: [],
          ),
        ),
        sources: {
          clip: [hls, sourceOf('clip-mp4')],
        },
      );
      addTearDown(backend.dispose);
      backend.create(clip).prepare();
      final player = await created();

      expect(player.source.playlistUrl, isNull);
      expect(published, ['clip-mp4']);
    });

    test('an HLS source names its kind and the HLS MIME type', () {
      expect(hls.kind, PlayerSourceKind.hls);
      expect(hls.mimeType, PlayerSource.hlsMimeType);
      expect(sourceOf('clip').kind, PlayerSourceKind.progressive);
      expect(
        PlayerSource(hls.request, mimeType: 'application/x-mpegURL').kind,
        PlayerSourceKind.hls,
      );
    });
  });

  group('the platform session', () {
    setUp(() => backend = backendOver(SimulatedHost()));
    tearDown(() => backend.dispose());

    AudioFocusContract.run(() => backend.audioFocus);

    PictureInPictureContract.run(() => backend.pictureInPicture);

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

    test('closing the window pauses its player; returning does not', () async {
      await settle();
      final engine = backend.create(clip)..prepare();
      for (var i = 0; i < 10; i++) {
        await settle();
      }
      engine.play();
      final pip = backend.pictureInPicture;

      pip
        ..start(engine)
        ..stop();
      await settle();
      expect(engine.state.value.playing, isTrue);

      pip.start(engine);
      await settle();
      host.dismissPictureInPicture(host.live.single.id);
      await settle();
      expect(pip.active.value, isNull);
      expect(engine.state.value.playing, isFalse);
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

/// A stopwatch the test moves by hand.
final class _ManualClock implements Stopwatch {
  Duration _elapsed = Duration.zero;

  void advance(Duration by) => _elapsed += by;

  @override
  Duration get elapsed => _elapsed;

  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;

  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;

  @override
  int get elapsedTicks => _elapsed.inMicroseconds;

  @override
  int get frequency => 1000000;

  @override
  bool get isRunning => true;

  @override
  void reset() => _elapsed = Duration.zero;

  @override
  void start() {}

  @override
  void stop() {}
}

/// A timer that never fires: the test runs the watchdog's check itself.
final class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}
