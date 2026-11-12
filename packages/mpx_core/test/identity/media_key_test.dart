import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  group('equality', () {
    test('the same variant and id are one key', () {
      expect(const MediaKey.remote('5368'), const MediaKey.remote('5368'));
      expect(
        const MediaKey.remote('5368').hashCode,
        const MediaKey.remote('5368').hashCode,
      );
      expect(const MediaKey.external('a'), const MediaKey.external('a'));
    });

    test('the same id under two variants is two keys', () {
      expect(const MediaKey.remote('a'), isNot(const MediaKey.external('a')));
    });

    test('ids are compared exactly', () {
      expect(const MediaKey.remote('a'), isNot(const MediaKey.remote('A')));
    });
  });

  group('local', () {
    const uuid = '3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91';

    test('the uuid is canonical in lower case', () {
      final key = MediaKey.local(uuid.toUpperCase()) as MediaKey$Local;
      expect(key.uuid, uuid);
      expect(MediaKey.local(uuid.toUpperCase()), MediaKey.local(uuid));
    });

    test('a local key never equals a remote key of the same text', () {
      expect(MediaKey.local(uuid), isNot(const MediaKey.remote(uuid)));
    });

    test('anything but a uuid is refused', () {
      expect(() => MediaKey.local('not-a-uuid'), throwsArgumentError);
      expect(() => MediaKey.local(''), throwsArgumentError);
      expect(
        () => MediaKey.local('3f1c2a7e9b4d4c1e8a2f0d5e6b7c8a91'),
        throwsArgumentError,
      );
    });
  });

  group('encoded', () {
    test('names the variant and keeps a plain id as it is', () {
      expect(const MediaKey.remote('5368').encoded, 'remote-5368');
      expect(
        const MediaKey.external('abc_1.x~y').encoded,
        'external-abc_1.x~y',
      );
      expect(
        MediaKey.local('3F1C2A7E-9B4D-4C1E-8A2F-0D5E6B7C8A91').encoded,
        'local-3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91',
      );
    });

    test('escapes everything a file name cannot hold', () {
      const key = MediaKey.external('https://host/a b?c=*:');
      expect(key.encoded, 'external-https%3A%2F%2Fhost%2Fa%20b%3Fc%3D%2A%3A');
      expect(key.encoded, matches(RegExp(r'^[A-Za-z0-9._~%-]+$')));
    });

    test('escapes non-ASCII as UTF-8 bytes', () {
      expect(const MediaKey.remote('é').encoded, 'remote-%C3%A9');
    });

    test('reads back to an equal key', () {
      final keys = [
        const MediaKey.remote('5368'),
        const MediaKey.remote('-:%/é'),
        const MediaKey.external('https://host/a b'),
        MediaKey.local('3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91'),
      ];
      for (final key in keys) {
        expect(MediaKey.parse(key.encoded), key);
        expect(MediaKey.tryParse(key.encoded), key);
      }
    });

    test('reads escapes in either case', () {
      expect(MediaKey.parse('remote-%c3%a9'), const MediaKey.remote('é'));
    });

    test('tryParse answers null for anything it did not write', () {
      for (final source in [
        null,
        '',
        'remote',
        'remote-',
        'remote:5368',
        'document-5368',
        'remote-a b',
        'remote-%zz',
        'remote-%C3',
        'local-not-a-uuid',
      ]) {
        expect(MediaKey.tryParse(source), isNull, reason: '$source');
      }
    });

    test('parse throws a FormatException for anything else', () {
      expect(() => MediaKey.parse('remote:5368'), throwsFormatException);
    });
  });

  test('toString names the variant and the id', () {
    expect(const MediaKey.remote('5368').toString(), 'MediaKey.remote(5368)');
    expect(const MediaKey.external('a').toString(), 'MediaKey.external(a)');
  });
}
