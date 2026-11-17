import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  const key = MediaKey.remote('1');

  test('a descriptor of a bare key knows nothing beyond it', () {
    const descriptor = MediaDescriptor(key: key);
    expect(descriptor.kind, MediaKind.unknown);
    expect(descriptor.animated, isFalse);
    expect(descriptor.dimensions, isNull);
    expect(descriptor.byteSize, isNull);
    expect(descriptor.duration, isNull);
    expect(descriptor.thumbnail, isNull);
    expect(descriptor.preview, isNull);
    expect(descriptor.streamable, isFalse);
  });

  test('two descriptors with the same facts are equal', () {
    MediaDescriptor make() => const MediaDescriptor(
      key: key,
      kind: MediaKind.video,
      animated: true,
      dimensions: MediaDimensions(640, 360),
      byteSize: 1024,
      duration: Duration(seconds: 3),
      thumbnail: MediaThumbnailRef('t'),
      streamable: true,
    );
    expect(make(), make());
    expect(make().hashCode, make().hashCode);
  });

  test('any differing fact makes another descriptor', () {
    const base = MediaDescriptor(key: key, kind: MediaKind.still);
    for (final other in [
      const MediaDescriptor(key: MediaKey.remote('2'), kind: MediaKind.still),
      const MediaDescriptor(key: key, kind: MediaKind.video),
      const MediaDescriptor(key: key, kind: MediaKind.still, animated: true),
      const MediaDescriptor(
        key: key,
        kind: MediaKind.still,
        dimensions: MediaDimensions(1, 1),
      ),
      const MediaDescriptor(key: key, kind: MediaKind.still, byteSize: 1),
      const MediaDescriptor(
        key: key,
        kind: MediaKind.still,
        duration: Duration.zero,
      ),
      const MediaDescriptor(
        key: key,
        kind: MediaKind.still,
        thumbnail: MediaThumbnailRef('t'),
      ),
      MediaDescriptor(
        key: key,
        kind: MediaKind.still,
        preview: MediaPreview.raster(Uint8List.fromList([1])),
      ),
      const MediaDescriptor(key: key, kind: MediaKind.still, streamable: true),
    ]) {
      expect(other, isNot(base));
    }
  });

  test('dimensions compare by value', () {
    expect(const MediaDimensions(2, 3), const MediaDimensions(2, 3));
    expect(const MediaDimensions(2, 3), isNot(const MediaDimensions(3, 2)));
    expect(const MediaDimensions(2, 3).toString(), 'MediaDimensions(2 x 3)');
  });

  group('a preview', () {
    test('of raster bytes equals one of the same bytes in another list', () {
      final a = MediaPreview.raster(Uint8List.fromList([0xFF, 0xD8, 7, 9]));
      final b = MediaPreview.raster(Uint8List.fromList([0xFF, 0xD8, 7, 9]));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        MediaDescriptor(key: key, preview: a),
        MediaDescriptor(key: key, preview: b),
      );
      expect(
        MediaDescriptor(key: key, preview: a).hashCode,
        MediaDescriptor(key: key, preview: b).hashCode,
      );
    });

    test('of other raster bytes is another preview', () {
      expect(
        MediaPreview.raster(Uint8List.fromList([1, 2, 3])),
        isNot(MediaPreview.raster(Uint8List.fromList([1, 2, 4]))),
      );
      expect(
        MediaPreview.raster(Uint8List.fromList([1, 2])),
        isNot(MediaPreview.raster(Uint8List.fromList([1, 2, 0]))),
      );
    });

    test('keeps its bytes: a change to the list it was given changes '
        'nothing', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final preview = MediaPreview.raster(bytes) as MediaPreview$Raster;

      bytes[0] = 9;

      expect(preview.encoded, [1, 2, 3]);
      expect(preview, MediaPreview.raster(Uint8List.fromList([1, 2, 3])));
    });

    test('of an outline compares path and view box by value', () {
      const box = MediaDimensions(512, 512);
      expect(
        const MediaPreview.outline('M0 0L1 1z', box),
        const MediaPreview.outline('M0 0L1 1z', MediaDimensions(512, 512)),
      );
      expect(
        const MediaPreview.outline('M0 0L1 1z', box).hashCode,
        const MediaPreview.outline('M0 0L1 1z', box).hashCode,
      );
      expect(
        const MediaPreview.outline('M0 0L1 1z', box),
        isNot(const MediaPreview.outline('M0 0L2 2z', box)),
      );
      expect(
        const MediaPreview.outline('M0 0L1 1z', box),
        isNot(const MediaPreview.outline('M0 0L1 1z', MediaDimensions(1, 1))),
      );
    });

    test('a raster is never an outline', () {
      expect(
        MediaPreview.raster(Uint8List(0)),
        isNot(const MediaPreview.outline('', MediaDimensions(1, 1))),
      );
    });
  });

  test('a descriptor says what it carries', () {
    final descriptor = MediaDescriptor(
      key: key,
      kind: MediaKind.video,
      preview: MediaPreview.raster(Uint8List(3)),
      streamable: true,
    );

    expect(descriptor.toString(), contains('preview: raster'));
    expect(descriptor.toString(), contains('streamable'));
    expect(
      const MediaDescriptor(key: key).toString(),
      'MediaDescriptor($key, unknown)',
    );
  });
}
