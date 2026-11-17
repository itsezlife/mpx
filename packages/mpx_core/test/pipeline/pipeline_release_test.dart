import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import 'pipeline_harness.dart';

/// Content that holds something (a file lease, a published resource) is
/// given back once: by the decode that took it, or by the pipeline when no
/// decode does.
void main() {
  group('fetched content', () {
    test('goes to the decoder unreleased', () async {
      final item = sticker(1);
      final harness = PipelineHarness(known: [item], autoDecode: false);
      addTearDown(harness.dispose);
      var released = 0;
      harness.fetcher.serve(
        item.key,
        FetchedContent.file('/a.webp', onRelease: () => released++),
      );

      harness.attach(item);
      await harness.settle();

      expect(harness.decoder.decodes, hasLength(1));
      expect(released, 0);
    });

    test('that waits for a decode slot is released when the attempt is '
        'cancelled', () async {
      final first = sticker(1);
      final second = sticker(2);
      final harness = PipelineHarness(
        known: [first, second],
        autoDecode: false,
        limits: const AssetPipelineLimits(maxConcurrentDecodes: 1),
      );
      addTearDown(harness.dispose);
      var released = 0;
      harness.fetcher.serve(
        second.key,
        FetchedContent.file('/b.webp', onRelease: () => released++),
      );

      harness.attach(first);
      final waiting = harness.attach(second);
      await harness.settle();
      expect(harness.decoder.decodes, hasLength(1));

      waiting.detach();
      await harness.settle();

      expect(released, 1);
    });

    test('that arrives after its attempt was cancelled is released', () async {
      final item = sticker(1);
      final fetcher = _LateFetcher();
      final decoder = FakeDecoder();
      final pipeline = AssetPipeline(
        fetcher: fetcher,
        decoders: DecoderRegistry()..register(MediaKind.still, decoder),
      )..know(item);
      final scope = AssetCacheScope(
        producer: pipeline,
        clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      );
      addTearDown(() {
        scope.dispose();
        pipeline.dispose();
      });
      var released = 0;

      scope.attach(item.key, spec, profile).detach();
      await Future<void>.delayed(Duration.zero);
      fetcher.pending.complete(
        FetchedContent.file('/a.webp', onRelease: () => released++),
      );
      await Future<void>.delayed(Duration.zero);

      expect(released, 1);
      expect(decoder.decodes, isEmpty);
    });

    test('is released by a fake decode that ends', () async {
      final item = sticker(1);
      final harness = PipelineHarness(known: [item]);
      addTearDown(harness.dispose);
      var released = 0;
      harness.fetcher.serve(
        item.key,
        FetchedContent.file('/a.webp', onRelease: () => released++),
      );

      harness.attach(item);
      await harness.settle();

      expect(harness.decoder.decodes.single.isSettled, isTrue);
      expect(released, 1);
    });

    test('of bytes has nothing to release', () {
      expect(bytes.release, returnsNormally);
    });
  });
}

/// A fetcher that answers even after its fetch was cancelled: what a fetch
/// whose bytes were already there does when the cancel comes a moment late.
final class _LateFetcher implements ContentFetcher {
  late Completer<FetchedContent> pending;

  @override
  Future<FetchedContent> fetch(FetchRequest request) =>
      (pending = Completer<FetchedContent>()).future;

  @override
  bool needsDownload(MediaKey key) => false;
}
