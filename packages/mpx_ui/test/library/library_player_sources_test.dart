import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  late FakeMediaLibrary library;

  setUp(() => library = FakeMediaLibrary(assets: 8));
  tearDown(() => library.dispose());

  test('a library video plays its file in place', () async {
    // Every fourth fake asset is a video.
    final video = LibraryKeys.libraryKeyOf(FakeMediaLibrary.assetAt(3));
    final sources = await LibraryPlayerSources.of(library, video);
    expect(sources, [
      PlayerSource.local(Uri(scheme: 'fake-library', path: 'asset-3')),
    ]);
    expect(sources.single.kind, PlayerSourceKind.local);
  });

  test('a photo, a thumbnail and a key from elsewhere have none', () async {
    final photo = FakeMediaLibrary.assetAt(0);
    expect(
      await LibraryPlayerSources.of(library, LibraryKeys.libraryKeyOf(photo)),
      isEmpty,
    );
    expect(
      await LibraryPlayerSources.of(
        library,
        LibraryKeys.thumbnailKeyOf(FakeMediaLibrary.assetAt(3), 96),
      ),
      isEmpty,
    );
    expect(
      await LibraryPlayerSources.of(library, const MediaKey.remote('clip')),
      isEmpty,
    );
  });
}
