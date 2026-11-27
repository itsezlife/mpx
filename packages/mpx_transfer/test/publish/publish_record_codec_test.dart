import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/publish/publish_record.dart';

const PublishRecordCodec _codec = PublishRecordCodec();

// Through JSON text, as a journal frame holds it.
Map<String, Object?> _stored(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

Map<String, Object?> _prepared(String path) => {
  'v': 1,
  'kind': 'photo',
  'path': path,
  'isOriginal': false,
  'byteSize': 10,
  'mimeType': 'image/jpeg',
  'width': 4,
  'height': 3,
  'durationUs': null,
  'thumbnailPath': null,
  'thumbnailWidth': null,
  'thumbnailHeight': null,
  'hasAudio': false,
  'animated': false,
};

/// A record in the stored form version 1 writes, every field and every
/// item progress present: records already on disk look like this.
Map<String, Object?> _fixture() => _stored({
  'v': 1,
  'id': 'p-01',
  'tag': 'chat:1',
  'publisher': 'messages',
  'transport': 'tus',
  'payload': base64Encode(utf8.encode('host')),
  'durability': 'system',
  'failurePolicy': 'wholeJob',
  'orderingGroup': 'chat:1',
  'groupOrder': 3,
  'hold': true,
  'committed': true,
  'awaitingOwner': true,
  'idempotencyKey': 'key-1',
  'keyFromRequest': true,
  'createdAt': '2026-01-02T03:04:05.000Z',
  'updatedAt': '2026-01-02T03:04:06.000Z',
  'attempts': 2,
  'reuploads': 1,
  'aliases': {'a': const MediaKey.remote('r1').encoded},
  'items': [
    {
      'itemId': 'a',
      'key': const MediaKey.remote('r1').encoded,
      'fingerprint': 'asset-1',
      'fileName': 'a.jpg',
      'source': {
        'is': 'prepare',
        'input': {
          'v': 1,
          'path': '/in/a',
          'mimeType': 'image/jpeg',
          'byteSize': 10,
        },
        'intent': {'v': 1, 'as': 'photo', 'highQuality': false},
      },
      'progress': {'is': 'waiting'},
    },
    {
      'itemId': 'b',
      'key': const MediaKey.remote('r2').encoded,
      'source': {'is': 'prepared', 'media': _prepared('/out/b')},
      'progress': {
        'is': 'prepared',
        'media': _prepared('/out/b'),
        'reuseKey': '["host:b"]',
      },
    },
    {
      'itemId': 'c',
      'key': const MediaKey.remote('r3').encoded,
      'source': {'is': 'remote'},
      'progress': {
        'is': 'uploading',
        'media': _prepared('/out/c'),
        'file': 'u-1',
        'thumbnail': 'u-2',
        'reuseKey': '["host:c"]',
      },
    },
    {
      'itemId': 'd',
      'key': const MediaKey.remote('r4').encoded,
      'source': {'is': 'remote'},
      'progress': {
        'is': 'uploaded',
        'file': {
          'id': 'remote-d',
          'attributes': {'etag': 'x'},
        },
        'thumbnail': {'id': 'remote-d-thumb'},
        'reused': true,
        'media': _prepared('/out/d'),
        'reuseKey': '["host:d"]',
        'uploads': ['u-3', 'u-4'],
      },
    },
    {
      'itemId': 'e',
      'key': const MediaKey.remote('r5').encoded,
      'source': {'is': 'remote'},
      'progress': {
        'is': 'failed',
        'stage': 'upload',
        'reason': 'server',
        'retryable': true,
        'before': {'is': 'prepared', 'media': _prepared('/out/e')},
      },
    },
  ],
  'end': {'is': 'completed', 'result': base64Encode(utf8.encode('done'))},
  'progress': 0.5,
});

/// [_fixture] with [change] applied to its first item's progress.
Map<String, Object?> _withProgress(Map<String, Object?> progress) {
  final json = _fixture();
  final items = json['items']! as List<Object?>;
  (items.first! as Map<String, Object?>)['progress'] = progress;
  return json;
}

Matcher _formatError(String field) => isA<FormatException>()
    .having((error) => error.message, 'message', contains('"$field"'))
    .having((error) => error.source, 'source', isA<Map<String, Object?>>());

void main() {
  group('PublishRecordCodec', () {
    test('a stored record decodes and encodes back to the same bytes', () {
      final stored = _fixture();
      final record = _codec.decode(stored);

      expect(jsonEncode(_codec.encode(record)), jsonEncode(stored));
      expect(record.items.map((item) => item.progress.runtimeType), [
        ItemProgress$Waiting,
        ItemProgress$Prepared,
        ItemProgress$Uploading,
        ItemProgress$Uploaded,
        ItemProgress$Failed,
      ]);
      expect(
        record.items[3].progress,
        isA<ItemProgress$Uploaded>().having(
          (progress) => progress.file,
          'file',
          RemoteRef('remote-d', attributes: const {'etag': 'x'}),
        ),
      );
    });

    test('a record at its defaults leaves them out and reads them back', () {
      final stored = _stored({
        'v': 1,
        'id': 'p-02',
        'payload': '',
        'durability': 'inProcess',
        'failurePolicy': 'wholeJob',
        'idempotencyKey': 'key-2',
        'keyFromRequest': false,
        'createdAt': '2026-01-02T03:04:05.000',
        'updatedAt': '2026-01-02T03:04:05.000',
        'attempts': 0,
        'items': <Object?>[],
      });
      final record = _codec.decode(stored);

      expect(record.hold, isFalse);
      expect(record.reuploads, 0);
      expect(record.aliases, isEmpty);
      expect(record.end, isNull);
      expect(record.progress, 0);
      expect(jsonEncode(_codec.encode(record)), jsonEncode(stored));
    });

    test('another version is refused', () {
      expect(
        () => _codec.decode({..._fixture(), 'v': 2}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('version'),
          ),
        ),
      );
    });

    test('a missing or wrong-typed field names the field', () {
      for (final (field, value) in [
        ('id', null),
        ('id', 7),
        ('keyFromRequest', 'yes'),
        ('attempts', 1.5),
        ('groupOrder', '3'),
        ('hold', 1),
        ('items', <String, Object?>{}),
        ('end', 'completed'),
        ('progress', 'half'),
      ]) {
        final json = _fixture();
        if (value == null) {
          json.remove(field);
        } else {
          json[field] = value;
        }
        expect(
          () => _codec.decode(json),
          throwsA(_formatError(field)),
          reason: '$field: $value',
        );
      }
    });

    test('an unknown name, tag, time, key or base64 names the field', () {
      for (final (field, json) in [
        ('durability', {..._fixture(), 'durability': 'forever'}),
        ('createdAt', {..._fixture(), 'createdAt': 'yesterday'}),
        ('payload', {..._fixture(), 'payload': '%%%'}),
        (
          'a',
          {
            ..._fixture(),
            'aliases': {'a': 'not a key'},
          },
        ),
        ('end', {..._fixture(), 'end': 7}),
        (
          'is',
          {
            ..._fixture(),
            'end': {'is': 'paused'},
          },
        ),
        ('is', _withProgress({'is': 'sending'})),
        ('stage', _withProgress({'is': 'failed', 'stage': 'send'})),
        ('media', _withProgress({'is': 'prepared'})),
        ('file', _withProgress({'is': 'uploading', 'media': _prepared('/')})),
        (
          'uploads',
          _withProgress({
            'is': 'uploaded',
            'uploads': [1],
          }),
        ),
        (
          'before',
          _withProgress({
            'is': 'failed',
            'stage': 'upload',
            'reason': 'x',
            'retryable': false,
            'before': 'prepared',
          }),
        ),
      ]) {
        expect(
          () => _codec.decode(json),
          throwsA(_formatError(field)),
          reason: field,
        );
      }
    });

    test('a running job cannot be written as an end', () {
      final record = _codec.decode(_fixture());
      expect(
        () => _codec.encode(
          record.copyWith(end: const PublishJobState.uploading()),
        ),
        throwsArgumentError,
      );
    });
  });

  group('result codecs', () {
    test('a remote reference without an id, or with a non-string '
        'attribute, names the field', () {
      const codec = RemoteRef.codec;
      expect(() => codec.decode({}), throwsA(_formatError('id')));
      expect(
        () => codec.decode({
          'id': 'r',
          'attributes': {'etag': 1},
        }),
        throwsA(_formatError('attributes')),
      );
    });
  });
}
