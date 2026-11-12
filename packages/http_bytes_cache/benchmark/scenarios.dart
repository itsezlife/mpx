import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';

import 'payloads.dart';
import 'sink.dart';

/// One store microbench row: prepare once, time [op] many times, then [dispose].
///
/// [op] returns an int folded into the runner sink so returned bytes cannot be
/// dead-code-eliminated. [bytes] is the payload size printed in the table
/// (0 when the row is not size-tiered).
final class StoreScenario {
  /// Creates a named scenario.
  const StoreScenario({
    required this.name,
    required this.bytes,
    required this.prepare,
  });

  /// Short stable id for tables and baseline keys.
  final String name;

  /// Payload size for the row, or `0` when not applicable.
  final int bytes;

  /// Opens caches / seeds data, then returns the timed body and cleanup.
  final Future<PreparedScenario> Function() prepare;
}

/// Ready-to-time body plus cleanup for one [StoreScenario].
final class PreparedScenario {
  /// Creates a prepared harness.
  const PreparedScenario({
    required this.op,
    required this.dispose,
  });

  /// One timed iteration. Return value feeds the sink.
  final Future<int> Function() op;

  /// Closes caches and deletes temp dirs. Idempotent-friendly.
  final Future<void> Function() dispose;
}

/// How a scenario obtains an [IBytesCache] for the timed body.
typedef _OpenCache =
    Future<({IBytesCache cache, Future<void> Function() dispose})> Function({
      required BytesRetention retention,
    });

/// Named [IBytesCache] scenarios (Memory + durable VM).
///
/// Isolation: each [StoreScenario.prepare] owns its temp durable directory and
/// closes the cache in [PreparedScenario.dispose]. Scenarios do not share
/// [BytesCache.shared].
List<StoreScenario> storeScenarios() {
  final small = payloadOf(smallBytes);
  final large = payloadOf(largeBytes);
  return [
    _warmHit('mem_warm_hit_small', small, _openMemory),
    _warmHit('mem_warm_hit_large', large, _openMemory),
    _concurrentReads('mem_concurrent_read_small', small, _openMemory),
    _writeEpoch('mem_write_epoch_small', small, _openMemory),
    _evict('mem_evict_small', small, _openMemory),
    _prune('mem_prune_small', small, _openMemory),
    _warmHit('durable_warm_hit_small', small, _openDurable),
    _warmHit('durable_warm_hit_large', large, _openDurable),
    _durableColdRoundTrip('durable_cold_roundtrip_small', small),
    _durableColdRoundTrip('durable_cold_roundtrip_large', large),
    _concurrentReads('durable_concurrent_read_small', small, _openDurable),
    _writeEpoch('durable_write_epoch_small', small, _openDurable),
    _writeEpoch('durable_write_epoch_large', large, _openDurable),
    _evict('durable_evict_small', small, _openDurable),
    _prune('durable_prune_small', small, _openDurable),
  ];
}

const _concurrentFanOut = 8;
const _writeEpochKeys = 8;
const _pruneSeedKeys = 24;
const _pruneMaxEntries = 8;

Future<({IBytesCache cache, Future<void> Function() dispose})> _openMemory({
  required BytesRetention retention,
}) async {
  final cache = MemoryBytesCache(retention: retention);
  return (cache: cache, dispose: cache.close);
}

Future<({IBytesCache cache, Future<void> Function() dispose})> _openDurable({
  required BytesRetention retention,
}) async {
  final dir = _tempDir();
  final cache = await BytesCache.open(
    directory: dir.path,
    retention: retention,
    throwOnOpenFailure: true,
  );
  return (cache: cache, dispose: () => _disposeDurable(cache, dir));
}

StoreScenario _warmHit(String name, Uint8List payload, _OpenCache open) =>
    StoreScenario(
      name: name,
      bytes: payload.length,
      prepare: () async {
        final opened = await open(retention: BytesRetention.standard);
        const key = BytesCacheKey('warm');
        await opened.cache.write(key, payload);
        return PreparedScenario(
          op: () async {
            final bytes = await opened.cache.read(key);
            return sinkBytes(bytes);
          },
          dispose: opened.dispose,
        );
      },
    );

StoreScenario _concurrentReads(
  String name,
  Uint8List payload,
  _OpenCache open,
) => StoreScenario(
  name: name,
  bytes: payload.length,
  prepare: () async {
    final opened = await open(retention: BytesRetention.standard);
    final keys = <BytesCacheKey>[
      for (var i = 0; i < _concurrentFanOut; i++) BytesCacheKey('c$i'),
    ];
    for (final key in keys) {
      await opened.cache.write(key, payload);
    }
    return PreparedScenario(
      op: () async {
        final results = await Future.wait(keys.map(opened.cache.read));
        var sink = 0;
        for (final bytes in results) {
          sink ^= sinkBytes(bytes);
        }
        return sink;
      },
      dispose: opened.dispose,
    );
  },
);

/// Soft-LRU touch of N keys, then one overflow [write] that flushes pending
/// access, capacity-trims, and durable-[commit]s once (real exclusive epoch).
StoreScenario _writeEpoch(String name, Uint8List payload, _OpenCache open) =>
    StoreScenario(
      name: name,
      bytes: payload.length,
      prepare: () async {
        final opened = await open(
          retention: const BytesRetention.maxEntries(_writeEpochKeys),
        );
        final keys = <BytesCacheKey>[
          for (var i = 0; i < _writeEpochKeys; i++) BytesCacheKey('w$i'),
        ];
        for (final key in keys) {
          await opened.cache.write(key, payload);
        }
        var overflow = 0;
        return PreparedScenario(
          op: () async {
            for (final key in keys) {
              await opened.cache.read(key);
            }
            final overflowKey = BytesCacheKey('overflow_$overflow');
            overflow++;
            await opened.cache.write(overflowKey, payload);
            return payload.length ^ overflow;
          },
          dispose: opened.dispose,
        );
      },
    );

StoreScenario _evict(String name, Uint8List payload, _OpenCache open) =>
    StoreScenario(
      name: name,
      bytes: payload.length,
      prepare: () async {
        final opened = await open(retention: BytesRetention.standard);
        const key = BytesCacheKey('evict');
        return PreparedScenario(
          op: () async {
            await opened.cache.write(key, payload);
            await opened.cache.evict(key);
            return payload.length;
          },
          dispose: opened.dispose,
        );
      },
    );

StoreScenario _prune(String name, Uint8List payload, _OpenCache open) =>
    StoreScenario(
      name: name,
      bytes: payload.length,
      prepare: () async {
        final opened = await open(
          retention: const BytesRetention.maxEntries(_pruneMaxEntries),
        );
        return PreparedScenario(
          op: () async {
            for (var i = 0; i < _pruneSeedKeys; i++) {
              await opened.cache.write(BytesCacheKey('p$i'), payload);
            }
            final report = await opened.cache.prune();
            return report.freedBytes ^ report.evictedKeys.length;
          },
          dispose: opened.dispose,
        );
      },
    );

/// Seed on disk, then each timed op is open → first read → close (cold durable
/// path after reopen; open cost is intentional).
StoreScenario _durableColdRoundTrip(String name, Uint8List payload) =>
    StoreScenario(
      name: name,
      bytes: payload.length,
      prepare: () async {
        final dir = _tempDir();
        const key = BytesCacheKey('cold');
        final seed = await BytesCache.open(
          directory: dir.path,
          retention: BytesRetention.standard,
          throwOnOpenFailure: true,
        );
        await seed.write(key, payload);
        await seed.close();
        return PreparedScenario(
          op: () async {
            final cache = await BytesCache.open(
              directory: dir.path,
              retention: BytesRetention.standard,
              throwOnOpenFailure: true,
            );
            try {
              final bytes = await cache.read(key);
              return sinkBytes(bytes);
            } finally {
              await cache.close();
            }
          },
          dispose: () async {
            if (dir.existsSync()) {
              dir.deleteSync(recursive: true);
            }
          },
        );
      },
    );

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('http_bytes_cache_bench_');

Future<void> _disposeDurable(IBytesCache cache, Directory dir) async {
  await cache.close();
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}
