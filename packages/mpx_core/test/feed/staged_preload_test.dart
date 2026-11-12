import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import '../pipeline/pipeline_harness.dart';

void main() {
  group('stages through the pipeline', () {
    late PipelineHarness harness;
    tearDown(() => harness.dispose());

    test('metadata resolves the descriptor and fetches nothing', () async {
      final clip = sticker(1);
      final resolver = FakeMediaResolver([clip]);
      harness = PipelineHarness(resolver: resolver, served: [clip]);

      harness.scope.preload(clip.key, spec, stage: AssetPreloadStage.metadata);
      await harness.settle();

      expect(resolver.requests, [
        [clip.key],
      ]);
      expect(harness.fetcher.fetches, isEmpty);

      // The descriptor is remembered: a later attach needs no resolve.
      harness.attach(clip);
      await harness.settle();
      expect(resolver.requests, hasLength(1));
    });

    test('seconds fetches a prefix and decodes nothing', () async {
      final clip = sticker(1, thumbnail: true);
      harness = PipelineHarness(known: [clip], autoDecode: false);

      harness.scope.preload(
        clip.key,
        spec,
        stage: const AssetPreloadStage.seconds(Duration(seconds: 3)),
      );
      await harness.settle();

      expect(harness.fetcher.fetches, hasLength(1));
      expect(harness.fetcher.fetches.single.request.part, FetchPart.content);
      expect(
        harness.fetcher.fetches.single.request.prefix,
        const Duration(seconds: 3),
      );
      expect(harness.decoder.decodes, isEmpty);
    });

    test('a binding during a prefix fetch gets the whole content', () async {
      final clip = sticker(1);
      harness = PipelineHarness(known: [clip], autoFetch: false);

      harness.scope.preload(
        clip.key,
        spec,
        stage: const AssetPreloadStage.seconds(Duration(seconds: 3)),
      );
      final binding = harness.attach(clip);
      harness.fetcher.fetches.single.complete(bytes);
      await harness.settle();

      expect(harness.fetcher.fetches, hasLength(2));
      expect(harness.fetcher.fetches.last.request.prefix, isNull);
      harness.fetcher.fetches.last.complete(bytes);
      await harness.settle();
      expect(binding.readiness.stage, AssetStage.full);
    });

    test('firstFrame stops after the first frame', () async {
      final clip = sticker(1);
      harness = PipelineHarness(known: [clip], firstFrameEarly: true);

      harness.scope.preload(
        clip.key,
        spec,
        stage: AssetPreloadStage.firstFrame,
      );
      await harness.settle();

      final binding = harness.attach(clip);
      expect(binding.readiness.stage, AssetStage.firstFrame);
      // The binding's own attempt goes on to the full asset.
      await harness.settle();
      expect(binding.readiness.stage, AssetStage.full);
    });

    test('the nearest preload is fetched first', () async {
      final keys = [for (var i = 0; i < 4; i++) sticker(i)];
      harness = PipelineHarness(
        known: keys,
        autoFetch: false,
        limits: const AssetPipelineLimits(maxConcurrentFetches: 1),
      );
      harness.attach(keys[0]);
      for (final (index, distance) in [(1, 2), (2, 0), (3, 1)]) {
        harness.scope.preload(
          keys[index].key,
          spec,
          stage: AssetPreloadStage.firstFrame,
          distance: distance,
        );
      }

      harness.fetcher.fetches.last.complete(bytes);
      await harness.settle();
      expect(harness.fetcher.fetches.last.request.descriptor.key, keys[2].key);

      harness.fetcher.fetches.last.complete(bytes);
      await harness.settle();
      expect(harness.fetcher.fetches.last.request.descriptor.key, keys[3].key);
    });

    test('cancelling the last claim cancels the fetch', () async {
      final clip = sticker(1);
      harness = PipelineHarness(known: [clip], autoFetch: false);

      final preload = harness.scope.preload(
        clip.key,
        spec,
        stage: AssetPreloadStage.firstFrame,
      );
      await harness.settle();
      preload
        ..cancel()
        ..cancel();

      expect(preload.isCancelled, isTrue);
      expect(harness.fetcher.fetches.single.isCancelled, isTrue);
    });
  });

  group('demand and pause layers', () {
    const key = MediaKey.remote('clip');
    const clipSpec = AssetSpec(pixelWidth: 64, pixelHeight: 64);
    late FakeAssetProducer producer;
    late PlaybackClock clock;
    late AssetCacheScope scope;

    setUp(() {
      producer = FakeAssetProducer();
      clock = PlaybackClock(ticks: ManualPlaybackTickSource());
      scope = AssetCacheScope(producer: producer, clock: clock);
    });
    tearDown(() {
      scope.dispose();
      clock.dispose();
    });

    test('preloads ask for the furthest stage and the nearest distance', () {
      scope.preload(key, clipSpec, stage: AssetPreloadStage.metadata);
      scope.preload(
        key,
        clipSpec,
        stage: const AssetPreloadStage.seconds(Duration(seconds: 5)),
        distance: 2,
      );
      final demand = producer.last.demand;

      expect(producer.attempts, hasLength(1));
      expect(demand.priority, AssetPriority.preload);
      expect(
        demand.preloadStage,
        const AssetPreloadStage.seconds(Duration(seconds: 5)),
      );
      expect(demand.distance, 0);

      scope.attach(key, clipSpec, const AssetProfile());
      expect(demand.preloadStage, isNull);
      expect(demand.priority, AssetPriority.visible);
    });

    test('a preload pins its entry until cancelled', () {
      final preload = scope.preload(
        key,
        clipSpec,
        stage: AssetPreloadStage.firstFrame,
      );
      producer.last.advance(AssetStage.firstFrame);
      producer.last.cancelled();
      scope.clearAll();
      expect(scope.contains(key, clipSpec), isTrue);

      preload.cancel();
      scope.clearAll();
      expect(scope.contains(key, clipSpec), isFalse);
    });

    for (final layer in AssetCacheScope.standardPreloadPausingLayers) {
      test('${layer.name} holds new preloads back until it clears', () {
        clock.setPaused(layer, paused: true);
        expect(scope.preloadsPaused, isTrue);

        scope.preload(key, clipSpec, stage: AssetPreloadStage.firstFrame);
        expect(producer.attempts, isEmpty);

        clock.setPaused(layer, paused: false);
        expect(producer.attempts, hasLength(1));
      });
    }

    test('bindings are never held back', () {
      clock.setPaused(PlaybackPauseLayer.meteredNetwork, paused: true);

      scope.attach(key, clipSpec, const AssetProfile());

      expect(producer.attempts, hasLength(1));
    });

    test('a layer outside the preload set does not hold preloads', () {
      clock.setPaused(PlaybackPauseLayer.overlayShown, paused: true);

      scope.preload(key, clipSpec, stage: AssetPreloadStage.metadata);

      expect(producer.attempts, hasLength(1));
    });
  });

  test('stages are ordered metadata < seconds < firstFrame', () {
    const short = AssetPreloadStage.seconds(Duration(seconds: 1));
    const long = AssetPreloadStage.seconds(Duration(seconds: 5));

    expect(AssetPreloadStage.metadata.furthest(short), short);
    expect(short.furthest(long), long);
    expect(
      long.furthest(AssetPreloadStage.firstFrame),
      AssetPreloadStage.firstFrame,
    );
    expect(
      AssetPreloadStage.firstFrame.furthest(AssetPreloadStage.metadata),
      AssetPreloadStage.firstFrame,
    );
  });
}
