import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

/// A [width] x [height] PNG, black on the left half and white on the right.
Future<Uint8List> _halves(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000),
    )
    ..drawRect(
      ui.Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Waits, in real time, until [done] or [within] passes.
Future<void> _until(
  bool Function() done, {
  Duration within = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _spec = AssetSpec(pixelWidth: 64, pixelHeight: 64);
const _profile = AssetProfile();

/// A scope over a pipeline that decodes with the engine codecs.
final class _Stack {
  _Stack(this.previews, {bool autoFetch = true, Decoder? vectors})
    : fetcher = FakeFetcher(autoRespond: autoFetch) {
    pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: DecoderRegistry()
        ..register(MediaKind.still, const ImageCodecDecoder())
        ..register(MediaKind.vectorAnimation, vectors ?? FakeDecoder()),
      previews: previews,
    );
    scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
  }

  final PreviewStore previews;
  final FakeFetcher fetcher;
  late final AssetPipeline pipeline;
  late final AssetCacheScope scope;

  void dispose() {
    scope.dispose();
    pipeline.dispose();
  }
}

void main() {
  late Uint8List photo;
  const key = MediaKey.remote('photo');
  const item = MediaDescriptor(
    key: key,
    kind: MediaKind.still,
    thumbnail: MediaThumbnailRef('thumb'),
  );

  setUpAll(() async => photo = await _halves(64, 32));

  test('content with no preview derives one from its first load, once, '
      'unblurred', () async {
    final store = FakePreviewStore();
    final stack = _Stack(store)..pipeline.know(item);
    addTearDown(stack.dispose);
    stack.fetcher
      ..serve(key, FetchedContent.bytes(photo))
      ..serveThumbnail(
        const MediaThumbnailRef('thumb'),
        FetchedContent.bytes(photo),
      );

    final binding = stack.scope.attach(key, _spec, _profile);
    await _until(() => store.writes.isNotEmpty);
    binding.detach();
    final again = stack.scope.attach(
      key,
      const AssetSpec(pixelWidth: 32, pixelHeight: 32),
      _profile,
    );
    await _until(() => again.readiness.isFinal);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(store.writes, hasLength(1));
    final (written, png) = store.writes.single;
    expect(written, key);
    final codec = await ui.instantiateImageCodec(png);
    final frame = (await codec.getNextFrame()).image;
    expect((frame.width, frame.height), (40, 20));
    final pixels = (await frame.toByteData())!;
    final row = [
      for (var x = 0; x < 40; x++) pixels.getUint8((10 * 40 + x) * 4),
    ];
    // Unblurred: black, then white, with at most a pixel between.
    expect(row.where((red) => red > 8 && red < 247).length, lessThan(2));
    frame.dispose();
    codec.dispose();
  });

  test('a later attach in the process draws the derived preview in its '
      'attach frame', () async {
    final store = FakePreviewStore();
    final stack = _Stack(store)..pipeline.know(item);
    addTearDown(stack.dispose);
    stack.fetcher.serve(key, FetchedContent.bytes(photo));
    final first = stack.scope.attach(key, _spec, _profile);
    await _until(() => store.writes.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    first.detach();
    // Nothing of the content is left in the cache to borrow from.
    stack.scope.clearAll();

    final other = stack.scope.attach(key, _spec, _profile);

    expect(other.readiness.stage, AssetStage.preview);
  });

  test('a stored preview is drawn after a restart, before any fetch '
      'answers', () async {
    final store = FakePreviewStore()..write(key, photo);
    store.reopen();
    final stack = _Stack(store, autoFetch: false)..pipeline.know(item);
    addTearDown(stack.dispose);

    final binding = stack.scope.attach(key, _spec, _profile);
    await _until(() => binding.readiness.stage == AssetStage.preview);

    expect(binding.readiness.stage, AssetStage.preview);
    expect(store.reads, [key]);
  });

  test('a descriptor preview wins over the store', () async {
    final store = FakePreviewStore()..write(key, photo);
    final stack = _Stack(store, autoFetch: false)
      ..pipeline.know(
        MediaDescriptor(
          key: key,
          kind: MediaKind.still,
          preview: MediaPreview.raster(photo),
        ),
      );
    addTearDown(stack.dispose);

    final binding = stack.scope.attach(key, _spec, _profile);
    await _until(() => binding.readiness.stage == AssetStage.preview);

    expect(store.peeks, isEmpty);
    expect(store.reads, isEmpty);
  });

  test('a store read that lands after the thumbnail is dropped', () async {
    final store = FakePreviewStore()..write(key, photo);
    store
      ..reopen()
      ..holdReads = true;
    final stack = _Stack(store, autoFetch: false)..pipeline.know(item);
    addTearDown(stack.dispose);
    stack.fetcher.serveThumbnail(
      const MediaThumbnailRef('thumb'),
      FetchedContent.bytes(photo),
    );
    final binding = stack.scope.attach(key, _spec, _profile);
    stack.fetcher.fetchesOf(key, FetchPart.thumbnail).single.complete();
    await _until(() => binding.readiness.stage == AssetStage.placeholder);

    store.releaseReads();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(binding.readiness.stage, AssetStage.placeholder);
  });

  test('a vector animation derives none: its outline is the host\'s', () async {
    final store = FakePreviewStore();
    const sticker = MediaDescriptor(
      key: MediaKey.remote('sticker'),
      kind: MediaKind.vectorAnimation,
      dimensions: MediaDimensions(512, 512),
    );
    final stack = _Stack(store)..pipeline.know(sticker);
    addTearDown(stack.dispose);
    stack.fetcher.serve(sticker.key, FetchedContent.bytes(photo));

    final binding = stack.scope.attach(sticker.key, _spec, _profile);
    await _until(() => binding.readiness.isFinal);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(binding.readiness.isFinal, isTrue);
    expect(store.writes, isEmpty);
  });

  PreviewStoreContract.run(() {
    final store = FakePreviewStore(maxBytes: 1000);
    return PreviewStoreHarness(
      store: store,
      reopen: () async => store..reopen(),
      quotaBytes: 1000,
    );
  });
}
