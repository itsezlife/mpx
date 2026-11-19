import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';

void main() {
  const photo = LibraryAsset(
    id: LibraryAssetId('42'),
    kind: LibraryAssetKind.photo,
    dimensions: MediaDimensions(4000, 3000),
  );
  const video = LibraryAsset(
    id: LibraryAssetId('A1B2/L0/001'),
    kind: LibraryAssetKind.video,
    dimensions: MediaDimensions(1080, 1920),
    duration: Duration(seconds: 7),
  );
  const gif = LibraryAsset(
    id: LibraryAssetId('7'),
    kind: LibraryAssetKind.photo,
    subtypes: {LibraryAssetSubtype.animated},
    mimeType: 'image/gif',
  );

  test('an asset is the external key device-library:<id>', () {
    expect(
      LibraryKeys.libraryKeyOf(photo),
      const MediaKey.external('device-library:42'),
    );
    expect(
      LibraryKeys.libraryKeyOf(video),
      const MediaKey.external('device-library:A1B2/L0/001'),
    );
  });

  test('keys read back to the asset id, through the stable form too', () {
    for (final asset in [photo, video, gif]) {
      final key = LibraryKeys.libraryKeyOf(asset);
      final target = LibraryKeys.read(MediaKey.parse(key.encoded));
      expect(target?.asset, asset.id);
      expect(target?.thumbnailPixels, isNull);
    }
  });

  test('a thumbnail key carries its pixel size and differs per size', () {
    final small = LibraryKeys.thumbnailKeyOf(photo, 96);
    final large = LibraryKeys.thumbnailKeyOf(photo, 320);
    expect(small, isNot(large));
    expect(small, isNot(LibraryKeys.libraryKeyOf(photo)));
    expect(LibraryKeys.read(small)?.asset, photo.id);
    expect(LibraryKeys.read(small)?.thumbnailPixels, 96);
    expect(LibraryKeys.read(large)?.thumbnailPixels, 320);
    expect(
      LibraryKeys.read(MediaKey.parse(large.encoded))?.thumbnailPixels,
      320,
    );
  });

  test('keys of other media are not library keys', () {
    expect(LibraryKeys.read(const MediaKey.remote('device-library:42')), null);
    expect(LibraryKeys.read(const MediaKey.external('https://a/b')), null);
    expect(
      LibraryKeys.read(const MediaKey.external('device-library-thumb:x:1')),
      null,
    );
    expect(
      LibraryKeys.read(MediaKey.local('3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91')),
      null,
    );
  });

  test('descriptors carry the kind, size and duration', () {
    final still = LibraryKeys.descriptorOf(photo);
    expect(still.key, LibraryKeys.libraryKeyOf(photo));
    expect(still.kind, MediaKind.still);
    expect(still.animated, isFalse);
    expect(still.dimensions, photo.dimensions);

    final moving = LibraryKeys.descriptorOf(video);
    expect(moving.kind, MediaKind.video);
    expect(moving.duration, const Duration(seconds: 7));

    final animated = LibraryKeys.descriptorOf(gif);
    expect(animated.kind, MediaKind.animatedImage);
    expect(animated.animated, isTrue);
  });

  test('a thumbnail descriptor is a still fitted into its pixels', () {
    final thumb = LibraryKeys.thumbnailDescriptorOf(video, 320);
    expect(thumb.key, LibraryKeys.thumbnailKeyOf(video, 320));
    expect(thumb.kind, MediaKind.still);
    expect(thumb.dimensions, const MediaDimensions(180, 320));
    expect(
      LibraryKeys.thumbnailDescriptorOf(gif, 96).dimensions,
      isNull,
      reason: 'an asset of unknown size has a thumbnail of unknown size',
    );
  });
}
