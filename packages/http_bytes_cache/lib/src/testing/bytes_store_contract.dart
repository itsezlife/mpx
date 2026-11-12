import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:test/test.dart';

/// Builds a fresh, empty [IBytesStore] for one contract test.
///
/// [clock] drives every timestamp the store takes; [retention] is the policy
/// under test.
typedef BytesStoreFactory =
    Future<IBytesStore> Function({
      required DateTime Function() clock,
      required BytesRetention retention,
    });

/// Behaviour every [IBytesStore] shares, whatever holds its payloads.
///
/// Call inside a test file's `main`; the suite registers its own group named
/// [name]. Each test closes the store it created.
void runBytesStoreContract(String name, BytesStoreFactory create) {
  group('$name honours the IBytesStore contract', () {
    late DateTime now;

    Future<IBytesStore> open({
      BytesRetention retention = const BytesRetention.unlimited(),
    }) async {
      final store = await create(clock: () => now, retention: retention);
      addTearDown(store.close);
      return store;
    }

    setUp(() => now = DateTime.utc(2026, 1, 1, 12));

    final bytes = Uint8List.fromList([1, 2, 3]);
    const key = BytesCacheKey('peeked');

    group('contains', () {
      test('answers false for a key never written', () async {
        final store = await open();
        expect(store.contains(key), isFalse);
      });

      test('answers true at once after a write', () async {
        final store = await open();
        await store.write(key, bytes);
        expect(store.contains(key), isTrue);
      });

      test('answers false after evict', () async {
        final store = await open();
        await store.write(key, bytes);
        await store.evict(key);
        expect(store.contains(key), isFalse);
      });

      test('answers false once the row is past its age', () async {
        final store = await open(
          retention: const BytesRetention.maxAge(Duration(days: 1)),
        );
        await store.write(key, bytes);
        now = now.add(const Duration(days: 2));
        expect(store.contains(key), isFalse);
      });
    });
  });
}
