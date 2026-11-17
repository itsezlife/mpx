import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const MediaKey _key = MediaKey.remote('loop');
final Uint8List _body = Uint8List.fromList(List.filled(16, 7));

void main() {
  late FakeDeviceSignals signals;
  late HttpBytesClient client;
  late List<String> requested;

  setUp(() {
    signals = FakeDeviceSignals();
    requested = [];
    client = HttpBytesClient(
      client: MockClient((request) async {
        requested.add(request.url.path);
        return http.Response.bytes(_body, 200);
      }),
    );
  });

  tearDown(() async {
    await client.close();
    signals.dispose();
  });

  Future<MpxStack> create({
    MpxDecoderFactory? decoders,
    Map<MediaKind, Decoder> fallbackDecoders = const {},
    Map<BytesQuota, QuotaEvictor> registeredQuotas = const {},
  }) async {
    final stack = await MpxStack.create(
      locate: (descriptor, _) =>
          MediaLocation('https://cdn.test/${descriptor.key.encoded}'),
      decoders: decoders,
      fallbackDecoders: fallbackDecoders,
      registeredQuotas: registeredQuotas,
      signals: signals,
      client: client,
      platformTextures: false,
    );
    addTearDown(stack.dispose);
    return stack;
  }

  testWidgets('the scope downloads by the network policy of the platform', (
    tester,
  ) async {
    final stack = await create();

    expect(stack.scope.autoDownload, same(stack.autoDownload));
    final policy = stack.autoDownload as NetworkAutoDownloadPolicy;
    expect(
      policy.presets,
      same(AutoDownloadPresets.forPlatform(defaultTargetPlatform)),
    );
    signals.network.value = NetworkClass.metered;
    expect(policy.network, NetworkClass.metered);
  });

  testWidgets('a host policy reaches the scope', (tester) async {
    final policy = FakeAutoDownloadPolicy();
    final stack = await MpxStack.create(
      locate: (descriptor, _) => const MediaLocation('https://cdn.test/x'),
      signals: signals,
      client: client,
      platformTextures: false,
      autoDownload: policy,
    );
    addTearDown(stack.dispose);

    expect(stack.scope.autoDownload, same(policy));
  });

  testWidgets('media reaches the host decoder through the bytes cache', (
    tester,
  ) async {
    final decoder = FakeDecoder();
    final stack = await create(decoders: (_) => {MediaKind.video: decoder});
    stack.pipeline.know(
      // Its size is known, so the default policy downloads it.
      const MediaDescriptor(key: _key, kind: MediaKind.video, byteSize: 16),
    );

    final binding = stack.scope.attach(
      _key,
      const AssetSpec(pixelWidth: 8, pixelHeight: 8),
      const AssetProfile(),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(requested, ['/${_key.encoded}']);
    expect(decoder.decodes, hasLength(1));
    final content = decoder.decodes.single.request.content as FetchedBytes;
    expect(content.bytes, _body);
    expect(stack.fetcher.needsDownload(_key), isFalse);
    binding.detach();
  });

  testWidgets('content its decoder cannot read goes to the kind\'s '
      'fallback', (tester) async {
    final decoder = FakeDecoder(autoRespond: false);
    final fallback = FakeDecoder(firstFrameOnly: true);
    final stack = await create(
      decoders: (_) => {MediaKind.video: decoder},
      fallbackDecoders: {MediaKind.video: fallback},
    );
    stack.pipeline.know(
      const MediaDescriptor(key: _key, kind: MediaKind.video, byteSize: 16),
    );

    final binding = stack.scope.attach(
      _key,
      const AssetSpec(pixelWidth: 8, pixelHeight: 8),
      const AssetProfile(),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    decoder.decodes.single.fail(const DecodeFailure.unsupported());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(fallback.decodes, hasLength(1));
    expect(
      binding.readiness,
      const AssetReadiness(AssetStage.firstFrame, isFinal: true),
    );
    binding.detach();
  });

  testWidgets('a store with files gets ranged resources, over which the '
      'publisher is built and video goes out published', (tester) async {
    final dir = Directory.systemTemp.createTempSync('mpx_stack_ranged_');
    final decoder = FakeDecoder(autoRespond: false);
    final publisher = FakeRangedContentPublisher();
    RangedBytes? builtOver;
    final stack = (await tester.runAsync(
      () => MpxStack.create(
        locate: (descriptor, _) =>
            MediaLocation('https://cdn.test/${descriptor.key.encoded}'),
        cacheDirectory: dir.path,
        decoders: (_) => {MediaKind.video: decoder},
        signals: signals,
        client: client,
        platformTextures: false,
        publisher: (ranged) {
          builtOver = ranged;
          return publisher;
        },
      ),
    ))!;
    addTearDown(() async {
      await tester.runAsync(stack.dispose);
      dir.deleteSync(recursive: true);
    });
    stack.pipeline.know(
      // Its size is known, so the default policy downloads it.
      const MediaDescriptor(key: _key, kind: MediaKind.video, byteSize: 16),
    );

    final binding = stack.scope.attach(
      _key,
      const AssetSpec(pixelWidth: 8, pixelHeight: 8),
      const AssetProfile(),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(stack.ranged, isNotNull);
    expect(builtOver, same(stack.ranged));
    expect(publisher.published.single.cacheKey.value, _key.encoded);
    expect(requested, isEmpty);
    expect(decoder.decodes.single.request.content, isA<FetchedRanged>());
    binding.detach();
  });

  testWidgets('a host decoder for a still replaces the engine codec', (
    tester,
  ) async {
    final decoder = FakeDecoder();
    final stack = await create(decoders: (_) => {MediaKind.still: decoder});
    stack.pipeline.know(
      const MediaDescriptor(key: _key, kind: MediaKind.still),
    );

    stack.scope
        .attach(
          _key,
          const AssetSpec(pixelWidth: 8, pixelHeight: 8),
          const AssetProfile(),
        )
        .detach();
    final binding = stack.scope.attach(
      _key,
      const AssetSpec(pixelWidth: 8, pixelHeight: 8),
      const AssetProfile(),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(decoder.decodes, hasLength(1));
    binding.detach();
  });

  testWidgets('host decoders share the stack clock', (tester) async {
    PlaybackClock? seen;
    final stack = await create(
      decoders: (context) {
        seen = context.clock;
        return const {};
      },
    );

    expect(seen, same(stack.scope.clock));
  });

  testWidgets('teardowns a decoder registers run on dispose', (tester) async {
    final log = <String>[];
    final stack = await create(
      decoders: (context) {
        context
          ..onDispose(() => log.add('engine'))
          ..onDispose(() => log.add('scheduler'));
        return const {};
      },
    );

    await stack.dispose();

    expect(log, ['scheduler', 'engine']);
  });

  testWidgets('power saving pauses playback', (tester) async {
    final stack = await create();
    final clock = stack.scope.clock;
    expect(clock.pausedLayers, isNot(contains(PlaybackPauseLayer.lowPower)));

    signals.powerSaving.value = true;
    expect(clock.pausedLayers, contains(PlaybackPauseLayer.lowPower));

    signals.powerSaving.value = false;
    expect(clock.pausedLayers, isNot(contains(PlaybackPauseLayer.lowPower)));
  });

  testWidgets('a serious thermal status pauses playback', (tester) async {
    final stack = await create();
    final clock = stack.scope.clock;

    signals.thermal.value = ThermalStatus.fair;
    expect(clock.pausedLayers, isNot(contains(PlaybackPauseLayer.lowPower)));

    signals.thermal.value = ThermalStatus.serious;
    expect(clock.pausedLayers, contains(PlaybackPauseLayer.lowPower));
  });

  testWidgets('host quota folders are registered with the store', (
    tester,
  ) async {
    final stack = await create(
      registeredQuotas: {BytesQuota.lottieFrames: (bytes) async => bytes},
    );

    final registration = stack.registeredQuotas[BytesQuota.lottieFrames.name];
    expect(registration, isNotNull);
    expect(
      () => stack.store.registerQuota(
        BytesQuota.lottieFrames,
        onEvict: (_) async => 0,
      ),
      throwsStateError,
      reason: 'the name is taken by the stack registration',
    );
  });

  testWidgets('derived previews go to the store under the previews quota', (
    tester,
  ) async {
    final stack = await create();
    final previews = stack.previews as BytesCachePreviewStore;
    const key = MediaKey.remote('derived');
    final png = Uint8List.fromList([9, 9, 9]);

    await tester.runAsync(() async {
      previews.write(key, png);
      await previews.flush();
      expect(
        await stack.store.read(BytesCachePreviewStore.cacheKeyOf(key)),
        png,
      );
    });
  });

  test('the standard quotas the stack opens include the previews', () {
    expect(BytesQuota.standard, contains(BytesQuota.previews));
  });
}
