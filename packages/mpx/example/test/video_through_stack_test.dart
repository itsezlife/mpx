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
  late Directory dir;
  NativeRangedReaders? attached;
  MpxStack? stack;

  setUp(() async {
    served = [];
    latency = Duration.zero;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final bytes = fixture.readAsBytesSync();
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
      response
        ..contentLength = last - start + 1
        ..add(bytes.sublist(start, last + 1));
      await response.close();
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

  Future<MpxStack> create({bool publish = true}) async =>
      stack = await MpxStack.create(
        locate: (descriptor, _) => MediaLocation(
          'http://127.0.0.1:${origin.port}/${descriptor.key.encoded}',
        ),
        cacheDirectory: dir.path,
        platformTextures: false,
        signals: FakeDeviceSignals(),
        client: HttpBytesClient(transfers: const HttpBytesTransfers()),
        publisher: publish
            ? (ranged) => NativeRangedContentPublisher(
                attached = NativeRangedReaders(ranged),
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
            MediaKind.video: VideoDecoder(engine: engine, scheduler: scheduler),
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
    return stack.scope.attach(
      key,
      const AssetSpec(pixelWidth: 128, pixelHeight: 96),
      const AssetProfile(),
    );
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

  // A published clip opens on a decode worker and blocks it on every read
  // the network has not answered yet, holding one of the pipeline's decode
  // slots meanwhile: a few far clips starve every other clip. The example
  // downloads clips whole, on the transfer worker, before they open.
  test(
    'clips still downloading never hold back a clip that is held',
    skip: skip,
    () async {
      latency = const Duration(seconds: 2);
      final created = await create(publish: false);
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
