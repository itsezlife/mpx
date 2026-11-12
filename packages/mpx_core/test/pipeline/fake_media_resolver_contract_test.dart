import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _still = MediaDescriptor(
  key: MediaKey.remote('1'),
  kind: MediaKind.still,
);
const _animation = MediaDescriptor(
  key: MediaKey.remote('5368'),
  kind: MediaKind.vectorAnimation,
  animated: true,
);

void main() {
  MediaResolverContract.run(
    () async => MediaResolverHarness(
      resolver: FakeMediaResolver([_still, _animation]),
      known: const [_still, _animation],
      unknownKey: const MediaKey.external('nobody'),
    ),
  );

  group('FakeMediaResolver', () {
    test('records each batch, repeats included', () async {
      final resolver = FakeMediaResolver([_still]);

      await resolver.resolve([_still.key, _still.key]);
      await resolver.resolve(const []);

      expect(resolver.requests, [
        [_still.key, _still.key],
        <MediaKey>[],
      ]);
    });

    test('fails every call on request', () async {
      final resolver = FakeMediaResolver([_still])
        ..failure = Exception('offline');

      await expectLater(resolver.resolve([_still.key]), throwsException);
      expect(resolver.requests, hasLength(1));
    });
  });
}
