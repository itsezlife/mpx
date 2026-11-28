import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

// Through JSON text, as a journal line would hold it.
Map<String, Object?> _stored(Map<String, Object?> encoded) =>
    (jsonDecode(jsonEncode(encoded)) as Map).cast<String, Object?>();

void main() {
  group('preparation codecs', () {
    test('an input round-trips, with and without its facts', () {
      const full = PreparationInput(
        '/picked/a.heic',
        mimeType: 'image/heic',
        byteSize: 1234,
      );
      const bare = PreparationInput('/picked/b.bin');

      for (final input in [full, bare]) {
        expect(
          const PreparationInputCodec().decode(
            _stored(const PreparationInputCodec().encode(input)),
          ),
          input,
        );
      }
    });

    test('every intent round-trips, every preset included', () {
      final intents = <PreparationIntent>[
        const PreparationIntent.photo(),
        const PreparationIntent.photo(highQuality: true),
        const PreparationIntent.video(),
        for (final preset in CompressionPreset.values)
          PreparationIntent.video(preset: preset),
        const PreparationIntent.file(),
      ];

      for (final intent in intents) {
        expect(
          const PreparationIntentCodec().decode(
            _stored(const PreparationIntentCodec().encode(intent)),
          ),
          intent,
        );
      }
    });

    test('a prepared item round-trips its file and facts', () {
      const video = PreparedMedia(
        kind: PreparedKind.video,
        path: '/out/1.mp4',
        isOriginal: false,
        byteSize: 5000000,
        mimeType: 'video/mp4',
        dimensions: MediaDimensions(1280, 720),
        duration: Duration(milliseconds: 12345),
        thumbnailPath: '/out/1.jpg',
        thumbnailDimensions: MediaDimensions(320, 180),
        hasAudio: true,
      );
      const original = PreparedMedia(
        kind: PreparedKind.file,
        path: '/picked/doc.pdf',
        isOriginal: true,
        byteSize: 42,
        animated: true,
      );

      for (final media in [video, original]) {
        expect(
          const PreparedMediaCodec().decode(
            _stored(const PreparedMediaCodec().encode(media)),
          ),
          media,
        );
      }
    });

    test('in-memory bytes are not stored', () {
      final media = PreparedMedia(
        kind: PreparedKind.photo,
        path: '/out/2.jpg',
        isOriginal: false,
        byteSize: 3,
        thumbnail: Uint8List.fromList([1, 2]),
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      final decoded = const PreparedMediaCodec().decode(
        _stored(const PreparedMediaCodec().encode(media)),
      );

      expect(decoded.thumbnail, isNull);
      expect(decoded.bytes, isNull);
      expect(decoded.path, '/out/2.jpg');
    });

    test('the stored form is pinned: version 1, names and keys', () {
      expect(PreparationInputCodec.version, 1);
      expect(
        const PreparationIntentCodec().encode(
          const PreparationIntent.video(preset: CompressionPreset.medium),
        ),
        {'v': 1, 'as': 'video', 'preset': 'medium'},
      );
      expect(
        const PreparationIntentCodec().encode(const PreparationIntent.photo()),
        {'v': 1, 'as': 'photo', 'highQuality': false},
      );
      expect(
        const PreparationIntentCodec().encode(const PreparationIntent.file()),
        {'v': 1, 'as': 'file'},
      );
      expect(
        const PreparationInputCodec().encode(
          const PreparationInput('/a', byteSize: 1),
        ),
        {'v': 1, 'path': '/a', 'mimeType': null, 'byteSize': 1},
      );
      expect(
        const PreparedMediaCodec().decode({
          'v': 1,
          'kind': 'photo',
          'path': '/out/3.jpg',
          'isOriginal': false,
          'byteSize': 10,
          'width': 4,
          'height': 3,
          'durationUs': null,
          'hasAudio': false,
          'animated': false,
        }),
        const PreparedMedia(
          kind: PreparedKind.photo,
          path: '/out/3.jpg',
          isOriginal: false,
          byteSize: 10,
          dimensions: MediaDimensions(4, 3),
        ),
      );
    });

    test('an unknown version, a missing key or an unknown name is a '
        'FormatException', () {
      expect(
        () => const PreparationIntentCodec().decode({'v': 2, 'as': 'file'}),
        throwsFormatException,
      );
      expect(
        () => const PreparationIntentCodec().decode({'as': 'file'}),
        throwsFormatException,
      );
      expect(
        () => const PreparationIntentCodec().decode({'v': 1, 'as': 'sticker'}),
        throwsFormatException,
      );
      expect(
        () => const PreparationIntentCodec().decode({
          'v': 1,
          'as': 'video',
          'preset': 'ultra',
        }),
        throwsFormatException,
      );
      expect(
        () => const PreparationInputCodec().decode({'v': 1}),
        throwsFormatException,
      );
      expect(
        () => const PreparedMediaCodec().decode({
          'v': 1,
          'kind': 'photo',
          'path': '/a',
          'isOriginal': false,
          'byteSize': '10',
          'hasAudio': false,
          'animated': false,
        }),
        throwsFormatException,
      );
    });

    test('a failed read names the key and carries the map read', () {
      final missing = <String, Object?>{'v': 1};
      expect(
        () => const PreparationInputCodec().decode(missing),
        throwsA(
          isA<FormatException>()
              .having((error) => error.message, 'message', contains('"path"'))
              .having((error) => error.source, 'source', same(missing)),
        ),
      );
      final wrong = <String, Object?>{'v': 1, 'as': 'photo', 'highQuality': 1};
      expect(
        () => const PreparationIntentCodec().decode(wrong),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'message',
                contains('"highQuality"'),
              )
              .having((error) => error.source, 'source', same(wrong)),
        ),
      );
    });
  });

  group('CompressionPreset', () {
    test('its names are its stored identity', () {
      expect(CompressionPreset.values.map((preset) => preset.name), [
        'tiny',
        'veryLow',
        'low',
        'medium',
        'high',
        'veryHigh',
      ]);
    });
  });
}
