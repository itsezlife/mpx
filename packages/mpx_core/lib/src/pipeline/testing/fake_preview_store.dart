import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/preview_store.dart';

/// A [PreviewStore] in memory with a memory tier ([peek]) over a "disk"
/// that outlives [reopen]. With [maxBytes] the disk forgets its oldest
/// previews past that many bytes. With [holdReads] each [read] waits for
/// [releaseReads].
final class FakePreviewStore implements PreviewStore {
  /// Creates an empty store.
  FakePreviewStore({this.maxBytes});

  /// The most bytes the disk keeps, or null for no limit.
  final int? maxBytes;

  final Map<MediaKey, Uint8List> _memory = {};
  final LinkedHashMap<MediaKey, Uint8List> _disk = LinkedHashMap();
  final List<Completer<void>> _held = [];

  /// Whether reads wait for [releaseReads].
  bool holdReads = false;

  /// Every key [peek] was asked for, in order.
  final List<MediaKey> peeks = [];

  /// Every key [read] was asked for, in order.
  final List<MediaKey> reads = [];

  /// Every write, in order.
  final List<(MediaKey, Uint8List)> writes = [];

  /// Forgets the memory tier, as a new process would; the disk stays.
  void reopen() => _memory.clear();

  /// Lets every held read answer.
  void releaseReads() {
    for (final held in List.of(_held)) {
      held.complete();
    }
    _held.clear();
  }

  @override
  Uint8List? peek(MediaKey key) {
    peeks.add(key);
    return _memory[key];
  }

  @override
  Future<Uint8List?> read(MediaKey key) async {
    reads.add(key);
    if (holdReads) {
      final held = Completer<void>();
      _held.add(held);
      await held.future;
    }
    return _memory[key] ?? _disk[key];
  }

  @override
  void write(MediaKey key, Uint8List png) {
    writes.add((key, png));
    _memory[key] = png;
    _disk
      ..remove(key)
      ..[key] = png;
    final max = maxBytes;
    if (max == null) return;
    var total = _disk.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
    while (total > max && _disk.length > 1) {
      final oldest = _disk.keys.first;
      total -= _disk.remove(oldest)!.length;
      _memory.remove(oldest);
    }
  }
}

/// What [PreviewStoreContract] runs against: a fresh [store], how to
/// [reopen] it as a new process would (the memory tier gone, the disk kept),
/// and the [quotaBytes] past which it forgets its oldest previews, if any.
final class PreviewStoreHarness {
  /// Creates a harness.
  PreviewStoreHarness({
    required this.store,
    required this.reopen,
    this.quotaBytes,
  });

  /// The store under test.
  final PreviewStore store;

  /// The same disk behind a new store.
  final Future<PreviewStore> Function() reopen;

  /// The bytes the store keeps before it evicts, or null to skip eviction.
  final int? quotaBytes;
}

/// The behaviour every [PreviewStore] owes the pipeline.
abstract final class PreviewStoreContract {
  /// Registers the contract's tests over the harness [create] makes.
  static void run(FutureOr<PreviewStoreHarness> Function() create) {
    const key = MediaKey.remote('preview');
    final png = Uint8List.fromList(List.generate(64, (i) => i));

    group('PreviewStore contract', () {
      test('knows nothing it was not given', () async {
        final harness = await create();
        expect(harness.store.peek(key), isNull);
        expect(await harness.store.read(key), isNull);
      });

      test('a write is peeked at once', () async {
        final harness = await create();
        harness.store.write(key, png);
        expect(harness.store.peek(key), png);
        expect(await harness.store.read(key), png);
      });

      test('a write is read after a reopen', () async {
        final harness = await create();
        harness.store.write(key, png);
        final reopened = await harness.reopen();
        expect(reopened.peek(key), isNull);
        expect(await reopened.read(key), png);
      });

      test('the oldest previews go past the quota', () async {
        final harness = await create();
        final quota = harness.quotaBytes;
        if (quota == null) return;
        final big = Uint8List(quota ~/ 2 + 1);
        for (var i = 0; i < 3; i++) {
          harness.store.write(MediaKey.remote('p$i'), big);
        }
        final reopened = await harness.reopen();
        expect(await reopened.read(const MediaKey.remote('p0')), isNull);
        expect(await reopened.read(const MediaKey.remote('p2')), isNotNull);
      });
    });
  }
}
