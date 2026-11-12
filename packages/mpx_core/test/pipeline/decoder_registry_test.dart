import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

void main() {
  group('DecoderRegistry', () {
    test('finds the decoder registered for a media form', () {
      final decoder = FakeDecoder();
      final registry = DecoderRegistry()..register(MediaKind.still, decoder);

      expect(registry.decoderFor(MediaKind.still), same(decoder));
      expect(registry.decoderFor(MediaKind.video), isNull);
    });

    test('refuses a second decoder for the same form', () {
      final registry = DecoderRegistry()
        ..register(MediaKind.still, FakeDecoder());

      expect(
        () => registry.register(MediaKind.still, FakeDecoder()),
        throwsStateError,
      );
    });

    test('refuses the unknown kind', () {
      final registry = DecoderRegistry();

      expect(
        () => registry.register(MediaKind.unknown, FakeDecoder()),
        throwsArgumentError,
      );
    });
  });
}
