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
    ]) {
      expect(other, isNot(base));
    }
  });

  test('dimensions compare by value', () {
    expect(const MediaDimensions(2, 3), const MediaDimensions(2, 3));
    expect(const MediaDimensions(2, 3), isNot(const MediaDimensions(3, 2)));
    expect(const MediaDimensions(2, 3).toString(), 'MediaDimensions(2 x 3)');
  });
}
