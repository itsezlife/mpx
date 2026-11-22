import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import 'pipeline_harness.dart';

/// A clip, and a scope whose video decoder (the software path) waits for the
/// test, with a still-only decoder registered as the fallback.
final class _Harness {
  _Harness({PreviewStore? previews, bool withFallback = true})
    : fetcher = FakeFetcher(),
      primary = FakeDecoder(autoRespond: false),
      fallback = FakeDecoder(autoRespond: false, firstFrameOnly: true) {
    final decoders = DecoderRegistry()..register(MediaKind.video, primary);
    if (withFallback) decoders.registerFallback(MediaKind.video, fallback);
    pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: decoders,
      previews: previews,
    )..know(clip);
    scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
    fetcher.serve(clip.key, bytes);
  }

  static const MediaDescriptor clip = MediaDescriptor(
    key: MediaKey.remote('clip'),
    kind: MediaKind.video,
    animated: true,
    dimensions: MediaDimensions(64, 32),
  );

  final FakeFetcher fetcher;
  final FakeDecoder primary;
  final FakeDecoder fallback;
  late final AssetPipeline pipeline;
  late final AssetCacheScope scope;

  AssetBinding attach([AssetSpec wanted = spec]) =>
      scope.attach(clip.key, wanted, profile);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void dispose() {
    scope.dispose();
    pipeline.dispose();
  }
}

void main() {
  group('DecoderRegistry fallbacks', () {
    test('finds the fallback registered for a media form', () {
      final decoder = FakeDecoder();
      final registry = DecoderRegistry()
        ..registerFallback(MediaKind.video, decoder);

      expect(registry.fallbackFor(MediaKind.video), same(decoder));
      expect(registry.fallbackFor(MediaKind.still), isNull);
      expect(registry.decoderFor(MediaKind.video), isNull);
    });

    test('refuses a second fallback and the unknown kind', () {
      final registry = DecoderRegistry()
        ..registerFallback(MediaKind.video, FakeDecoder());

      expect(
        () => registry.registerFallback(MediaKind.video, FakeDecoder()),
        throwsStateError,
      );
      expect(
        () => registry.registerFallback(MediaKind.unknown, FakeDecoder()),
        throwsArgumentError,
      );
    });
  });

  group('a content the decoder cannot read', () {
    test('is decoded by the fallback after unsupported', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();

      harness.primary.decodes.single.fail(
        const DecodeFailure.unsupported('no av1 in this build'),
      );
      await harness.settle();

      expect(harness.fallback.decodes, hasLength(1));
      final retry = harness.fallback.decodes.single;
      expect(retry.request.part, FetchPart.content);
      expect(retry.request.spec, spec);
      expect(
        harness.fetcher.fetchesOf(_Harness.clip.key, FetchPart.content),
        hasLength(2),
        reason: 'the first decoder released its content: it is fetched again',
      );

      retry.complete();

      expect(
        binding.readiness,
        const AssetReadiness(AssetStage.firstFrame, isFinal: true),
        reason: 'a still is the best the fallback makes for a full spec',
      );
      expect(binding.lastError, isNull);
    });

    test('stays final at the first frame for the next binding', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final first = harness.attach();
      await harness.settle();
      harness.primary.decodes.single.fail(const DecodeFailure.unsupported());
      await harness.settle();
      harness.fallback.decodes.single.complete();

      final second = harness.attach();
      await harness.settle();

      expect(second.readiness, first.readiness);
      expect(harness.primary.decodes, hasLength(1));
      expect(harness.fallback.decodes, hasLength(1));
    });

    test('a failure for any other cause does not fall back', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();

      harness.primary.decodes.single.fail(const FormatException('damaged'));
      await harness.settle();

      expect(harness.fallback.decodes, isEmpty);
      expect(binding.readiness.stage, AssetStage.none);
      expect(binding.lastError, isA<FormatException>());
    });

    test('content the decoder reads never reaches the fallback', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();

      harness.primary.decodes.single.complete();

      expect(binding.readiness.stage, AssetStage.full);
      expect(harness.fallback.decodes, isEmpty);
    });

    test('without a fallback, unsupported fails as any decode', () async {
      final harness = _Harness(withFallback: false);
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();

      harness.primary.decodes.single.fail(const DecodeFailure.unsupported());
      await harness.settle();

      expect(binding.readiness.stage, AssetStage.none);
      expect(binding.lastError, isA<DecodeFailure>());
    });

    test('a fallback that cannot read it either fails for good', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();
      harness.primary.decodes.single.fail(const DecodeFailure.unsupported());
      await harness.settle();

      harness.fallback.decodes.single.fail(const DecodeFailure.unsupported());
      await harness.settle();

      expect(harness.fallback.decodes, hasLength(1));
      expect(harness.primary.decodes, hasLength(1));
      expect(binding.readiness.stage, AssetStage.none);
      expect(binding.lastError, isA<DecodeFailure>());
    });

    test('a content with a stored derived preview skips the fallback: the '
        'still was paid for once', () async {
      final store = FakePreviewStore()..write(_Harness.clip.key, await _png());
      final harness = _Harness(previews: store);
      addTearDown(harness.dispose);
      final binding = harness.attach();
      await harness.settle();
      await _untilPreview(binding);

      harness.primary.decodes.single.fail(const DecodeFailure.unsupported());
      await harness.settle();

      expect(harness.fallback.decodes, isEmpty);
      expect(binding.readiness.stage, AssetStage.preview);
    });

    test('a still is handed to its fallback even with a stored derived '
        'preview: a preview never stands for a still\'s own picture', () async {
      const drawing = MediaDescriptor(
        key: MediaKey.remote('drawing'),
        kind: MediaKind.still,
      );
      final store = FakePreviewStore()..write(drawing.key, await _png());
      final fetcher = FakeFetcher()
        ..serve(drawing.key, FetchedContent.bytes(Uint8List(4)));
      final primary = FakeDecoder(autoRespond: false);
      final fallback = FakeDecoder();
      final pipeline = AssetPipeline(
        fetcher: fetcher,
        decoders: DecoderRegistry()
          ..register(MediaKind.still, primary)
          ..registerFallback(MediaKind.still, fallback),
        previews: store,
      )..know(drawing);
      final scope = AssetCacheScope(
        producer: pipeline,
        clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      );
      addTearDown(() {
        scope.dispose();
        pipeline.dispose();
      });
      final binding = scope.attach(drawing.key, spec, profile);
      await _untilPreview(binding);
      for (var i = 0; i < 200 && primary.decodes.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      primary.decodes.single.fail(const DecodeFailure.unsupported());
      for (var i = 0; i < 200 && !binding.readiness.isFinal; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(fallback.decodes, hasLength(1));
      expect(binding.readiness.stage, AssetStage.full);
    });
  });
}

Future<void> _untilPreview(AssetBinding binding) async {
  for (var i = 0; i < 200; i++) {
    if (binding.readiness.stage == AssetStage.preview) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 4),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 4);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
