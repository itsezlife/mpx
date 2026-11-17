import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import 'pipeline_harness.dart';

/// A resolver that answers when the test says so.
final class _HeldResolver implements MediaResolver {
  final List<List<MediaKey>> requests = [];
  final List<Completer<Map<MediaKey, MediaDescriptor>>> _answers = [];

  void answer(int request, Iterable<MediaDescriptor> descriptors) =>
      _answers[request].complete({
        for (final descriptor in descriptors) descriptor.key: descriptor,
      });

  void failRequest(int request, Object error) =>
      _answers[request].completeError(error);

  @override
  Future<Map<MediaKey, MediaDescriptor>> resolve(Iterable<MediaKey> keys) {
    requests.add(keys.toList());
    final answer = Completer<Map<MediaKey, MediaDescriptor>>();
    _answers.add(answer);
    return answer.future;
  }
}

void main() {
  group('a bare key', () {
    test('is resolved by the host, then fetched and decoded', () async {
      final item = sticker(1);
      final resolver = FakeMediaResolver([item]);
      final harness = PipelineHarness(served: [item], resolver: resolver);
      addTearDown(harness.dispose);

      final binding = harness.attachKey(item.key);
      expect(binding.readiness.stage, AssetStage.none);
      await harness.settle();

      expect(resolver.requests, [
        [item.key],
      ]);
      expect(binding.readiness.stage, AssetStage.full);
    });

    test('stays at none, with nothing fetched, until it resolves', () async {
      final item = sticker(1);
      final resolver = _HeldResolver();
      final harness = PipelineHarness(served: [item], resolver: resolver);
      addTearDown(harness.dispose);

      final binding = harness.attachKey(item.key);
      await harness.settle();

      expect(binding.readiness.stage, AssetStage.none);
      expect(harness.fetcher.fetches, isEmpty);

      resolver.answer(0, [item]);
      await harness.settle();

      expect(binding.readiness.stage, AssetStage.full);
    });

    test('keys attached in one turn are resolved in one batch', () async {
      final items = [for (var n = 1; n <= 4; n++) sticker(n)];
      final resolver = FakeMediaResolver(items);
      final harness = PipelineHarness(served: items, resolver: resolver);
      addTearDown(harness.dispose);

      for (final item in items) {
        harness.attachKey(item.key);
      }
      harness.attachKey(items.first.key, firstFrameSpec);
      await harness.settle();

      expect(resolver.requests, hasLength(1));
      expect(
        resolver.requests.single,
        unorderedEquals(items.map((i) => i.key)),
      );
    });

    test('is resolved once for all the sizes it is shown at', () async {
      final item = sticker(1);
      final resolver = FakeMediaResolver([item]);
      final harness = PipelineHarness(served: [item], resolver: resolver);
      addTearDown(harness.dispose);

      harness.attachKey(item.key);
      await harness.settle();
      harness.attachKey(item.key, firstFrameSpec);
      await harness.settle();

      expect(resolver.requests, hasLength(1));
    });

    test(
      'a key the host does not know ends the attempt, permanently',
      () async {
        final item = sticker(1);
        final resolver = FakeMediaResolver(const []);
        final harness = PipelineHarness(served: [item], resolver: resolver);
        addTearDown(harness.dispose);

        final binding = harness.attachKey(item.key);
        await harness.settle();
        harness.scope.connectivityRestored();
        await harness.settle();

        expect(binding.lastError, isA<AssetPipelineError>());
        expect(binding.readiness.stage, AssetStage.none);
        expect(
          resolver.requests,
          hasLength(1),
          reason: 'not retried on connectivity',
        );
        binding.retry();
        await harness.settle();
        expect(resolver.requests, hasLength(2));
      },
    );

    test('a resolver that cannot be reached is a transient failure', () async {
      final item = sticker(1);
      final resolver = FakeMediaResolver([item])
        ..failure = Exception('no connection');
      final harness = PipelineHarness(served: [item], resolver: resolver);
      addTearDown(harness.dispose);
      final binding = harness.attachKey(item.key);
      await harness.settle();
      expect(binding.lastError, isException);

      resolver.failure = null;
      harness.scope.connectivityRestored();
      await harness.settle();

      expect(binding.readiness.stage, AssetStage.full);
    });

    test('without a resolver is an error to see in the logs only', () async {
      final item = sticker(1);
      final harness = PipelineHarness(served: [item]);
      addTearDown(harness.dispose);

      final binding = harness.attachKey(item.key);
      await harness.settle();

      expect(binding.lastError, isA<AssetPipelineError>());
      expect(binding.readiness.stage, AssetStage.none);
      expect(harness.fetcher.fetches, isEmpty);
    });

    test(
      'leaving while it resolves fetches nothing, and keeps the answer',
      () async {
        final item = sticker(1);
        final resolver = _HeldResolver();
        final harness = PipelineHarness(served: [item], resolver: resolver);
        addTearDown(harness.dispose);
        final leaving = harness.attachKey(item.key);
        await harness.settle();
        leaving.detach();

        resolver.answer(0, [item]);
        await harness.settle();
        expect(harness.fetcher.fetches, isEmpty);

        final binding = harness.attachKey(item.key);
        await harness.settle();

        expect(resolver.requests, hasLength(1), reason: 'the answer was kept');
        expect(binding.readiness.stage, AssetStage.full);
      },
    );
  });

  group('a bare key that leaves in the same turn', () {
    test('is never asked for', () async {
      final item = sticker(1);
      final resolver = FakeMediaResolver([item]);
      final harness = PipelineHarness(served: [item], resolver: resolver);
      addTearDown(harness.dispose);

      harness.attachKey(item.key).detach();
      await harness.settle();

      expect(resolver.requests, isEmpty);
      expect(harness.fetcher.fetches, isEmpty);
    });
  });

  group('known descriptors', () {
    test('a descriptor the host gave needs no resolver', () async {
      final item = sticker(1);
      final resolver = FakeMediaResolver(const []);
      final harness = PipelineHarness(known: [item], resolver: resolver);
      addTearDown(harness.dispose);

      final binding = harness.attachKey(item.key);
      await harness.settle();

      expect(resolver.requests, isEmpty);
      expect(binding.readiness.stage, AssetStage.full);
    });

    test('the least recently used one is forgotten past the limit', () async {
      final items = [for (var n = 1; n <= 3; n++) sticker(n)];
      final resolver = FakeMediaResolver(items);
      final harness = PipelineHarness(
        known: items,
        resolver: resolver,
        limits: const AssetPipelineLimits(knownDescriptors: 2),
      );
      addTearDown(harness.dispose);

      harness.attachKey(items[2].key);
      harness.attachKey(items[1].key);
      expect(resolver.requests, isEmpty);

      harness.attachKey(items[0].key);
      await harness.settle();

      expect(resolver.requests, [
        [items[0].key],
      ]);
    });
  });

  group('the descriptor of an entry', () {
    test('a known one reaches the binding in the attach frame', () {
      const item = MediaDescriptor(
        key: MediaKey.remote('clip'),
        kind: MediaKind.still,
        byteSize: 2048,
        duration: Duration(seconds: 3),
      );
      final harness = PipelineHarness(known: [item]);
      addTearDown(harness.dispose);

      final binding = harness.attach(item);

      expect(binding.descriptor, item);
    });

    test('a resolved one reaches the binding after the resolve, with one '
        'signal', () async {
      final item = sticker(1);
      final resolver = _HeldResolver();
      final harness = PipelineHarness(
        served: [item],
        resolver: resolver,
        autoFetch: false,
      );
      addTearDown(harness.dispose);
      final binding = harness.attachKey(item.key);
      var signals = 0;
      binding.addListener(() => signals++);
      await harness.settle();
      expect(binding.descriptor, isNull);

      resolver.answer(0, [item]);
      await harness.settle();

      expect(binding.descriptor, item);
      expect(signals, 1);
    });

    test('is never reported for a key the resolver does not know', () async {
      final item = sticker(1);
      final resolver = _HeldResolver();
      final harness = PipelineHarness(resolver: resolver);
      addTearDown(harness.dispose);
      final binding = harness.attachKey(item.key);
      var signals = 0;
      binding.addListener(() => signals++);
      await harness.settle();

      resolver.answer(0, const []);
      await harness.settle();

      expect(binding.descriptor, isNull);
      expect(signals, 0);
    });

    test('stays with the entry for the next attach', () {
      final item = sticker(1);
      final harness = PipelineHarness(known: [item]);
      addTearDown(harness.dispose);

      harness.attach(item).detach();

      expect(harness.attach(item).descriptor, item);
    });
  });
}
