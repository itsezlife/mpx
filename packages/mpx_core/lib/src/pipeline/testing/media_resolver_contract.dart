import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/media_resolver.dart';

/// A [MediaResolver] under test, with the content the contract needs and
/// cannot invent.
final class MediaResolverHarness {
  /// Creates a harness around [resolver].
  const MediaResolverHarness({
    required this.resolver,
    required this.known,
    required this.unknownKey,
  });

  /// The resolver under test.
  final MediaResolver resolver;

  /// At least two descriptors the resolver resolves.
  final List<MediaDescriptor> known;

  /// A key the resolver cannot resolve.
  final MediaKey unknownKey;
}

/// The behaviour every [MediaResolver] must have, as a test suite to run
/// against an implementation.
abstract final class MediaResolverContract {
  /// Runs the [MediaResolver] contract against the harnesses [create]
  /// returns, one per test.
  static void run(Future<MediaResolverHarness> Function() create) {
    group('MediaResolver contract', () {
      late MediaResolverHarness harness;
      late MediaResolver resolver;

      setUp(() async {
        harness = await create();
        resolver = harness.resolver;
      });

      test('resolves nothing to an empty result', () async {
        expect(await resolver.resolve(const []), isEmpty);
      });

      test('resolves a key to its descriptor', () async {
        final descriptor = harness.known.first;

        final result = await resolver.resolve([descriptor.key]);

        expect(result, {descriptor.key: descriptor});
      });

      test('resolves a batch in one call', () async {
        final keys = [for (final d in harness.known) d.key];

        final result = await resolver.resolve(keys);

        expect(result.keys.toSet(), keys.toSet());
        for (final descriptor in harness.known) {
          expect(result[descriptor.key], descriptor);
        }
      });

      test('lists every descriptor under its own key', () async {
        final result = await resolver.resolve([
          for (final d in harness.known) d.key,
        ]);

        for (final MapEntry(:key, :value) in result.entries) {
          expect(value.key, key);
        }
      });

      test('leaves an unknown key out rather than failing', () async {
        final known = harness.known.first;

        final result = await resolver.resolve([harness.unknownKey, known.key]);

        expect(result.containsKey(harness.unknownKey), isFalse);
        expect(result[known.key], known);
      });

      test('resolves only unknown keys to an empty result', () async {
        expect(await resolver.resolve([harness.unknownKey]), isEmpty);
      });

      test('never holds a key that was not asked for', () async {
        final asked = harness.known.first.key;

        final result = await resolver.resolve([asked]);

        expect(result.keys, [asked]);
      });

      test('accepts a key more than once', () async {
        final descriptor = harness.known.first;

        final result = await resolver.resolve([
          descriptor.key,
          descriptor.key,
          harness.unknownKey,
          harness.unknownKey,
        ]);

        expect(result, {descriptor.key: descriptor});
      });

      test('can be asked again for the same keys', () async {
        final keys = [for (final d in harness.known) d.key];

        final first = await resolver.resolve(keys);
        final second = await resolver.resolve(keys);

        expect(second, first);
      });
    });
  }
}
