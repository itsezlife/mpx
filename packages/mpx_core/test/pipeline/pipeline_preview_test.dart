import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

import 'pipeline_harness.dart';

/// A [side] x [side] grey PNG.
Future<Uint8List> _png(int side) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xFF808080));
  final picture = recorder.endRecording();
  final image = await picture.toImage(side, side);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Waits, in real time, until [binding] is at [stage] or [within] passes.
Future<void> _until(
  AssetBinding binding,
  AssetStage stage, {
  Duration within = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(within);
  while (binding.readiness.stage != stage &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

MediaDescriptor _withPreview(
  int n,
  Uint8List preview, {
  bool thumbnail = true,
}) => MediaDescriptor(
  key: MediaKey.remote('photo-$n'),
  kind: MediaKind.still,
  thumbnail: thumbnail ? MediaThumbnailRef('thumb-$n') : null,
  preview: MediaPreview.raster(preview),
);

void main() {
  late Uint8List png;

  setUpAll(() async => png = await _png(32));

  test('a raster preview is drawn before the thumbnail, the thumbnail before '
      'the content', () async {
    final item = _withPreview(1, png);
    final harness = PipelineHarness(known: [item], autoFetch: false);
    addTearDown(harness.dispose);
    final binding = harness.attach(item);
    final stages = <AssetStage>[];
    binding.addListener(() {
      if (stages.lastOrNull != binding.readiness.stage) {
        stages.add(binding.readiness.stage);
      }
    });
    expect(binding.readiness.stage, AssetStage.none);

    await _until(binding, AssetStage.preview);
    harness.fetcher.fetchesOf(item.key, FetchPart.thumbnail).single.complete();
    await harness.settle();
    harness.fetcher.fetchesOf(item.key, FetchPart.content).single.complete();
    await harness.settle();

    expect(stages, [
      AssetStage.preview,
      AssetStage.placeholder,
      AssetStage.full,
    ]);
    expect(binding.readiness.isFinal, isTrue);
  });

  test('the preview waits behind no fetch: it takes no fetch slot', () async {
    final busy = sticker(9);
    final item = _withPreview(1, png, thumbnail: false);
    final harness = PipelineHarness(
      known: [busy, item],
      autoFetch: false,
      limits: const AssetPipelineLimits(maxConcurrentFetches: 1),
    );
    addTearDown(harness.dispose);
    harness.attach(busy);

    final binding = harness.attach(item);
    await _until(binding, AssetStage.preview);

    expect(binding.readiness.stage, AssetStage.preview);
    expect(harness.fetcher.fetchesOf(item.key, FetchPart.content), isEmpty);
  });

  test('a re-attach draws the decoded preview in the attach frame, at any '
      'spec', () async {
    final item = _withPreview(1, png, thumbnail: false);
    final harness = PipelineHarness(known: [item], autoFetch: false);
    addTearDown(harness.dispose);
    final first = harness.attach(item);
    await _until(first, AssetStage.preview);
    first.detach();

    final again = harness.attach(item);
    final larger = harness.attach(
      item,
      const AssetSpec(pixelWidth: 128, pixelHeight: 128),
    );

    expect(again.readiness, const AssetReadiness(AssetStage.preview));
    expect(larger.readiness, const AssetReadiness(AssetStage.preview));
  });

  test('a preview that does not decode is ignored, as a failed thumbnail '
      'is', () async {
    final item = _withPreview(1, Uint8List.fromList([1, 2, 3]));
    final harness = PipelineHarness(known: [item]);
    addTearDown(harness.dispose);

    final binding = harness.attach(item);
    await _until(binding, AssetStage.full);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(binding.readiness.stage, AssetStage.full);
    expect(binding.lastError, isNull);
  });

  test('a preview that lands after the thumbnail is dropped', () async {
    final item = _withPreview(1, png);
    final harness = PipelineHarness(known: [item], autoFetch: false);
    addTearDown(harness.dispose);
    final binding = harness.attach(item);

    harness.fetcher.fetchesOf(item.key, FetchPart.thumbnail).single.complete();
    await harness.settle();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(binding.readiness.stage, AssetStage.placeholder);
  });

  test('a template decode draws no raster preview: it is alpha only', () async {
    final item = _withPreview(1, png, thumbnail: false);
    final harness = PipelineHarness(known: [item], autoFetch: false);
    addTearDown(harness.dispose);

    final binding = harness.attach(
      item,
      const AssetSpec(
        pixelWidth: 64,
        pixelHeight: 64,
        decodeMode: AssetDecodeMode.template,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(binding.readiness.stage, AssetStage.none);
  });

  group('an outline preview', () {
    MediaDescriptor sticker(String path) => MediaDescriptor(
      key: const MediaKey.remote('sticker'),
      kind: MediaKind.still,
      preview: MediaPreview.outline(path, const MediaDimensions(512, 512)),
    );

    test('is drawn in the attach frame', () {
      final item = sticker('M0 0H512V512Z');
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);

      final binding = harness.attach(item);

      expect(binding.readiness.stage, AssetStage.preview);
      expect(binding.paintable, isA<OutlinePaintable>());
    });

    test('is drawn for a template decode too: it has no colours', () {
      final item = sticker('M0 0H512V512Z');
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);

      final binding = harness.attach(
        item,
        const AssetSpec(
          pixelWidth: 64,
          pixelHeight: 64,
          decodeMode: AssetDecodeMode.template,
        ),
      );

      expect(binding.readiness.stage, AssetStage.preview);
    });

    test('that does not parse leaves the stage at none', () {
      final item = sticker('M0 0A5 5 0 0 1 10 0Z');
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);

      final binding = harness.attach(item);

      expect(binding.readiness.stage, AssetStage.none);
    });
  });
}
