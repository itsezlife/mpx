import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/http/byte_range.dart';
import 'package:http_bytes_cache/src/ranged/byte_range_set.dart';
import 'package:test/test.dart';

/// Builds a fresh, empty [IRangedBytesStore] for one contract test.
///
/// [clock] drives every timestamp the store takes; [retention] is its budget.
/// The store must count ranged rows against a `video_ranges` quota with no
/// limits of its own, so [retention] alone decides eviction.
typedef RangedBytesStoreFactory =
    Future<IRangedBytesStore> Function({
      required DateTime Function() clock,
      required BytesRetention retention,
    });

/// Behaviour every [IRangedBytesStore] that [IRangedBytesStore.supportsRanges]
/// shares: merging writes, dropping spans on a new validator, whole reads of
/// complete resources, and eviction of ranged resources whole.
///
/// Call inside a test file's `main`; the suite registers its own group named
/// [name]. Each test closes the store it created.
void runRangedBytesStoreContract(String name, RangedBytesStoreFactory create) {
  const video = BytesCacheKey('video');
  const other = BytesCacheKey('other');
  const v1 = HttpCacheMeta(etag: '"v1"');
  const v2 = HttpCacheMeta(etag: '"v2"');
  final body = Uint8List.fromList([for (var i = 0; i < 4000; i++) i % 251]);

  Uint8List slice(int start, int end) => body.sublist(start, end);

  // A clock that moves on every read, so last uses never tie.
  var now = DateTime.utc(2026);
  DateTime tick() => now = now.add(const Duration(seconds: 1));

  Future<IRangedBytesStore> open(BytesRetention retention) =>
      create(clock: tick, retention: retention);

  group('$name honours the IRangedBytesStore contract', () {
    group('ranges', () {
      late IRangedBytesStore store;

      setUp(() async {
        store = await open(BytesRetention.standard);
      });

      tearDown(() => store.close());

      test('supports ranges', () {
        expect(store.supportsRanges, isTrue);
      });

      test('overlapping writes merge into one range set', () async {
        await store.writeRange(video, 0, slice(0, 100), validator: v1);
        await store.writeRange(video, 50, slice(50, 150), validator: v1);
        final state = await store.writeRange(
          video,
          200,
          slice(200, 300),
          validator: v1,
          totalLength: 4000,
        );

        expect(state.ranges.spans, [(0, 150), (200, 300)]);
        expect(state.totalLength, 4000);
        expect(store.rangesOf(video)?.ranges, state.ranges);
        expect(
          await store.readRange(video, const ByteRange(20, 140)),
          slice(20, 140),
        );
        expect(await store.readRange(video, const ByteRange(100, 250)), isNull);
      });

      test('a changed validator drops every span', () async {
        await store.writeRange(video, 0, slice(0, 100), validator: v1);
        final state = await store.writeRange(
          video,
          500,
          slice(500, 600),
          validator: v2,
        );

        expect(state.ranges.spans, [(500, 600)]);
        expect(state.validator?.etag, '"v2"');
        expect(await store.readRange(video, const ByteRange(0, 100)), isNull);
      });

      test('resetRanges starts a new representation', () async {
        await store.writeRange(video, 0, slice(0, 100), validator: v1);
        final state = await store.resetRanges(
          video,
          validator: v2,
          totalLength: 4000,
        );

        expect(state.ranges.isEmpty, isTrue);
        expect(store.rangesOf(video)?.validator?.etag, '"v2"');
      });

      test(
        'an incomplete resource is not a whole hit; a complete one is',
        () async {
          await store.writeRange(
            video,
            0,
            slice(0, 2000),
            validator: v1,
            totalLength: 4000,
          );
          expect(store.contains(video), isFalse);
          expect(await store.read(video), isNull);
          expect(store.rangesOf(video), isNotNull);

          await store.writeRange(
            video,
            2000,
            slice(2000, 4000),
            validator: v1,
            totalLength: 4000,
          );
          expect(store.rangesOf(video)!.isComplete, isTrue);
          expect(store.contains(video), isTrue);
          expect(await store.read(video), body);
        },
      );

      test('openRanged leases a file before any byte lands', () async {
        final lease = await store.openRanged(video);
        addTearDown(lease.release);

        expect(store.rangesOf(video)?.ranges, ByteRangeSet.empty);
        expect(lease.key, video);
      });

      test('a whole write replaces a ranged row', () async {
        await store.writeRange(video, 0, slice(0, 100), validator: v1);
        await store.write(video, Uint8List.fromList([7, 7]));

        expect(store.rangesOf(video)?.ranges.spans, [(0, 2)]);
        expect(store.rangesOf(video)!.isComplete, isTrue);
        expect(await store.read(video), [7, 7]);
      });
    });

    group('eviction', () {
      late IRangedBytesStore store;

      setUp(() async {
        store = await open(const BytesRetention.maxBytes(1500));
      });

      tearDown(() => store.close());

      test('evicts the least recently used ranged resource whole', () async {
        await store.writeRange(video, 0, slice(0, 1000), validator: v1);
        await store.writeRange(other, 0, slice(0, 1000), validator: v1);
        await store.prune();

        expect(store.rangesOf(video), isNull);
        expect(store.rangesOf(other)?.ranges.coveredBytes, 1000);
      });

      test('never evicts a resource someone holds open', () async {
        final lease = await store.openRanged(video);
        await store.writeRange(video, 0, slice(0, 1000), validator: v1);
        await store.writeRange(other, 0, slice(0, 1000), validator: v1);
        await store.prune();

        expect(store.rangesOf(video)?.ranges.coveredBytes, 1000);
        expect(store.rangesOf(other), isNull);

        await lease.release();
      });
    });
  });
}
