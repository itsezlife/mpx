import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/native.dart';
import 'package:mpx/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

import 'support/mp4_layout.dart';

/// A clip from a ranged origin to its first frame through the example's own
/// wiring: the bytes store, the transfer client, the native reader, the
/// worker engine and the video decoder. What the device runs, on this
/// machine, on real timers (the stores and workers answer over ports).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = File(
    '../../mpx_video_decoder/native/probe/fixtures/h264_320x240_30fps_2s.mp4',
  ).absolute;
  final skip = !NativeRangedReaders.isAvailable
      ? 'no native reader'
      : !NativeVideoBinding.probe().isAvailable
      ? 'no native video library'
      : !fixture.existsSync()
      ? 'no fixture'
      : null;
  const descriptor = MediaDescriptor(
    key: MediaKey.remote('clip'),
    kind: MediaKind.video,
    animated: true,
  );

  late HttpServer origin;
  late List<String> served;
  // Before each answer: a far origin.
  var latency = Duration.zero;
  // Bytes per second each answer is held to; null for no limit.
  int? rate;
  // Body bytes sent so far, over every answer.
  var sent = 0;
  // What a path serves other than the fixture.
  final bodies = <String, Uint8List>{};
  late Directory dir;
  NativeRangedReaders? attached;
  MpxStack? stack;

  setUp(() async {
    served = [];
    latency = Duration.zero;
    rate = null;
    sent = 0;
    bodies.clear();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final bytes =
          bodies[request.uri.pathSegments.last] ?? fixture.readAsBytesSync();
      final response = request.response;
      final range = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(request.headers.value('range') ?? '');
      response.headers.set('accept-ranges', 'bytes');
      var start = 0;
      var last = bytes.length - 1;
      if (range != null) {
        start = int.parse(range.group(1)!);
        last = math.min(
          int.tryParse(range.group(2)!) ?? last,
          bytes.length - 1,
        );
        response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $start-$last/${bytes.length}');
      }
      served.add('${request.uri.path} ${request.headers.value('range')}');
      await Future<void>.delayed(latency);
      response.contentLength = last - start + 1;
      try {
        final limit = rate;
        if (limit == null) {
          response.add(bytes.sublist(start, last + 1));
          sent += last + 1 - start;
        } else {
          // In pieces at the rate, as a slow network delivers.
          const piece = 2048;
          for (var at = start; at <= last; at += piece) {
            final end = math.min(at + piece, last + 1);
            response.add(bytes.sublist(at, end));
            await response.flush();
            sent += end - at;
            await Future<void>.delayed(
              Duration(microseconds: piece * 1000000 ~/ limit),
            );
          }
        }
        await response.close();
      } on Object {
        // The client went away: a cancelled fetch.
      }
    });
    dir = Directory.systemTemp.createTempSync('video_through_stack_');
  });

  tearDown(() async {
    await stack?.dispose();
    stack = null;
    await attached?.close();
    attached = null;
    await origin.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Future<MpxStack> create({
    bool publish = true,
    int firstStretch = 8 * 1024,
  }) async => stack = await MpxStack.create(
    locate: (descriptor, _) => MediaLocation(
      'http://127.0.0.1:${origin.port}/${descriptor.key.encoded}',
    ),
    cacheDirectory: dir.path,
    platformTextures: false,
    signals: FakeDeviceSignals(),
    // These clips carry no size; the reference policy would wait for a tap.
    autoDownload: AutoDownloadPolicy.always,
    // Small pieces, so a test file of tens of kilobytes lands in many.
    client: HttpBytesClient(
      transfers: const HttpBytesTransfers(landBytes: 2048),
    ),
    publisher: publish
        ? (ranged) => NativeRangedContentPublisher(
            attached = NativeRangedReaders(ranged, readAheadBytes: 8192),
            firstStretchBytes: firstStretch,
          )
        : null,
    decoders: (context) async {
      final engine = await IsolateVideoEngine.spawn();
      final scheduler = VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(),
        clock: context.clock,
      );
      context
        ..onDispose(engine.dispose)
        ..onDispose(scheduler.dispose);
      return {
        MediaKind.video: VideoDecoder(
          engine: engine,
          scheduler: scheduler,
          rangedLookaheadBytes: 4096,
        ),
      };
    },
  );

  Future<AssetBinding> show(
    MpxStack stack,
    MediaKey key, {
    Uint8List? held,
  }) async {
    if (held != null) {
      await stack.store.write(
        BytesCacheFetcher.cacheKeyOf(key, FetchPart.content),
        held,
      );
    }
    stack.pipeline.know(
      MediaDescriptor(key: key, kind: MediaKind.video, animated: true),
    );
    // On screen, as a surface that shows it says.
    return stack.scope.attach(
      key,
      const AssetSpec(pixelWidth: 128, pixelHeight: 96),
      const AssetProfile(),
    )..visible = true;
  }

  Future<AssetBinding> attach({Uint8List? held}) async =>
      show(await create(), descriptor.key, held: held);

  Future<void> untilDrawn(AssetBinding binding) async {
    final clock = Stopwatch()..start();
    while (binding.readiness.stage.index < AssetStage.firstFrame.index) {
      if (clock.elapsed > const Duration(seconds: 20)) {
        fail(
          'no first frame in 20 s: ${binding.readiness}, '
          'error ${binding.lastError}, served $served',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'a clip not yet held plays from the native reader as it downloads',
    skip: skip,
    () async {
      final binding = await attach();

      await untilDrawn(binding);

      expect(served, isNotEmpty);
      binding.detach();
    },
  );

  test('a held clip plays from its file', skip: skip, () async {
    final binding = await attach(held: fixture.readAsBytesSync());

    await untilDrawn(binding);

    expect(served, isEmpty);
    binding.detach();
  });

  test(
    'a large clip draws its first frame after its first stretch, well '
    'before the whole file is here',
    skip: skip,
    () async {
      final length = fixture.lengthSync();
      // Four seconds for the whole file.
      rate = length ~/ 4;
      final clock = Stopwatch()..start();
      final binding = await attach();

      await untilDrawn(binding);

      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(sent, lessThan(length));
      binding.detach();
    },
  );

  test(
    'a clip whose moov follows its media data starts after the head and '
    'the tail, not the whole file',
    skip: skip,
    () async {
      final bytes = moovAtEnd(fixture.readAsBytesSync());
      final (moovStart, _) = boxSpan(bytes, 'moov');
      bodies['remote-clip'] = bytes;
      rate = bytes.length ~/ 4;
      final clock = Stopwatch()..start();
      final binding = await attach();

      await untilDrawn(binding);

      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
      expect(sent, lessThan(bytes.length));
      expect(
        served.any((line) => line.contains('bytes=$moovStart-')),
        isTrue,
        reason: 'the tail was asked for on its own: $served',
      );
      binding.detach();
    },
  );

  test(
    'a clip that leaves the screen stops its download, keeping what it has',
    skip: skip,
    () async {
      // The clip, then three megabytes nobody plays: the chunk fetched
      // ahead of its reads runs into them.
      final clip = fixture.readAsBytesSync();
      const padding = 3 * 1024 * 1024;
      final free = ByteData(8)
        ..setUint32(0, padding + 8)
        ..setUint32(4, 0x66726565);
      bodies['remote-clip'] = Uint8List.fromList([
        ...clip,
        ...free.buffer.asUint8List(),
        ...Uint8List(padding),
      ]);
      rate = 256 * 1024;
      final binding = await attach();
      await untilDrawn(binding);

      // Scrolled away: the entry stays, its surface no longer shows it.
      binding.visible = false;
      await Future<void>.delayed(const Duration(seconds: 2));

      // Kept on, the chunk ahead (512 KiB at 256 KiB a second) would be all
      // here by now; stopped, only what had come (and what the sockets
      // still held) is.
      expect(sent, lessThan(256 * 1024));
      final held = stack!.store as IRangedBytesStore;
      final state = held.rangesOf(
        BytesCacheFetcher.cacheKeyOf(descriptor.key, FetchPart.content),
      );
      expect(state!.ranges.coveredBytes, greaterThan(clip.length ~/ 2));
      binding.detach();
    },
  );

  // A clip whose bytes have not landed stalls and gives its worker turn and
  // its decode slot up, so a few far clips never hold back a clip that is
  // already here.
  test(
    'clips still downloading never hold back a clip that is held',
    skip: skip,
    () async {
      latency = const Duration(seconds: 2);
      final created = await create();
      final downloading = [
        for (var i = 0; i < 4; i++)
          await show(created, MediaKey.remote('far-$i')),
      ];
      // The downloads are under way before the held clip is asked for.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final clock = Stopwatch()..start();
      final held = await show(
        created,
        const MediaKey.remote('near'),
        held: fixture.readAsBytesSync(),
      );

      await untilDrawn(held);

      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
      for (final binding in downloading) {
        await untilDrawn(binding);
      }
      held.detach();
      for (final binding in downloading) {
        binding.detach();
      }
    },
  );
}
