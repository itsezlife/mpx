import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/src/library/library_access.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';
import 'package:mpx_library/src/library/library_change.dart';
import 'package:mpx_library/src/library/media_library.dart';

/// What a [MediaLibrary] contract run needs.
final class MediaLibraryHarness {
  /// Creates a harness over [library].
  ///
  /// [minimumAssets] is how many assets the all-media album holds at least
  /// once access is granted; the paging tests read up to that many. A
  /// platform run on a device with an empty library passes 0, and the paging
  /// tests then only check empty pages.
  const MediaLibraryHarness({required this.library, this.minimumAssets = 0});

  /// The library under test, fresh for each test.
  final MediaLibrary library;

  /// The assets the all-media album holds at least, with access.
  final int minimumAssets;
}

/// The contract every [MediaLibrary] meets; see its documentation.
abstract final class MediaLibraryContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test;
  /// the library is disposed after it.
  static void run(MediaLibraryHarness Function() create) {
    group('MediaLibrary contract', () {
      late MediaLibraryHarness harness;
      MediaLibrary library() => harness.library;

      setUp(() => harness = create());
      tearDown(() => harness.library.dispose());

      Future<LibraryAlbum?> allMedia() async {
        await library().requestAccess();
        final albums = await library().albums();
        return albums.isEmpty ? null : albums.first;
      }

      test('access transitions notify and requestAccess reports the '
          'outcome', () async {
        final seen = <LibraryAccess>[];
        void listener() => seen.add(library().access.value);
        library().access.addListener(listener);
        final before = library().access.value;
        final after = await library().requestAccess();
        library().access.removeListener(listener);

        expect(library().access.value, after);
        if (after != before) {
          expect(seen, isNotEmpty, reason: 'a transition notifies');
          expect(seen.last, after);
        } else {
          expect(seen, isEmpty, reason: 'no transition, no notification');
        }
        if (before != LibraryAccess.notDetermined) {
          expect(after, before, reason: 'only notDetermined is asked');
        }
      });

      test('without read access albums and pages are empty', () async {
        if (library().access.value.canRead) return;
        expect(await library().albums(), isEmpty);
        final page = await library().page(
          const LibraryAlbumId('any'),
          offset: 0,
          limit: 10,
        );
        expect(page.assets, isEmpty);
      });

      test('the all-media album comes first', () async {
        final album = await allMedia();
        if (!library().access.value.canRead) return;
        expect(album, isNotNull);
        expect(album!.kind, LibraryAlbumKind.allMedia);
        expect(album.count, greaterThanOrEqualTo(harness.minimumAssets));
        final albums = await library().albums();
        expect(
          albums.where((a) => a.kind == LibraryAlbumKind.allMedia),
          hasLength(1),
        );
        for (final a in albums) {
          expect(a.count, greaterThanOrEqualTo(0));
        }
      });

      test('paging is gap-free and stable across pages', () async {
        final album = await allMedia();
        if (album == null) return;
        final span = album.count < 30 ? album.count : 30;
        final paged = <LibraryAssetId>[];
        for (var offset = 0; offset < span; offset += 7) {
          final limit = offset + 7 > span ? span - offset : 7;
          final page = await library().page(
            album.id,
            offset: offset,
            limit: limit,
          );
          expect(page.offset, offset);
          expect(page.assets.length, limit, reason: 'a full window in range');
          paged.addAll(page.assets.map((a) => a.id));
        }
        final whole = await library().page(album.id, offset: 0, limit: span);
        expect(paged, whole.assets.map((a) => a.id).toList());
        expect(paged.toSet(), hasLength(paged.length), reason: 'no duplicates');
      });

      test('an offset past the end returns an empty page', () async {
        final album = await allMedia();
        if (album == null) return;
        final atEnd = await library().page(
          album.id,
          offset: album.count,
          limit: 10,
        );
        expect(atEnd.assets, isEmpty);
        expect(atEnd.isLast, isTrue);
        final pastEnd = await library().page(
          album.id,
          offset: album.count + 100,
          limit: 10,
        );
        expect(pastEnd.assets, isEmpty);
        final tail = await library().page(
          album.id,
          offset: album.count > 3 ? album.count - 3 : 0,
          limit: 10,
        );
        expect(tail.assets.length, album.count > 3 ? 3 : album.count);
        expect(tail.isLast, isTrue);
      });

      test('pages read again without a change event return the same '
          'assets', () async {
        final album = await allMedia();
        if (album == null) return;
        final events = <LibraryChange>[];
        final subscription = library().changes.listen(events.add);
        final first = await library().page(album.id, offset: 0, limit: 12);
        final second = await library().page(album.id, offset: 0, limit: 12);
        await subscription.cancel();
        if (events.isEmpty) {
          expect(
            second.assets.map((a) => a.id).toList(),
            first.assets.map((a) => a.id).toList(),
          );
        }
      });

      test('manageSelected acts only under limited or partial '
          'access', () async {
        await library().requestAccess();
        if (library().access.value.canManageSelected) return;
        final before = library().access.value;
        expect(await library().manageSelected(), isFalse);
        expect(library().access.value, before);
      });

      test('a thumbnail and an original of an asset are readable', () async {
        final album = await allMedia();
        if (album == null || album.count == 0) return;
        final page = await library().page(album.id, offset: 0, limit: 1);
        final asset = page.assets.single;
        final thumbnail = await library().thumbnail(asset.id, pixels: 96);
        expect(thumbnail, isNotEmpty);

        final lease = await library().original(asset.id);
        expect(File(lease.path).existsSync(), isTrue);
        await lease.release();
        await lease.release();
      });

      test('reads of an unknown asset fail as unavailable', () async {
        await library().requestAccess();
        const missing = LibraryAssetId('mpx-contract-missing-asset');
        await expectLater(
          library().thumbnail(missing, pixels: 96),
          throwsA(isA<LibraryAssetUnavailable>()),
        );
        await expectLater(
          library().original(missing),
          throwsA(isA<LibraryAssetUnavailable>()),
        );
        expect(library().isCloudHeld(missing), isFalse);
        expect(await library().playable(missing), isNull);
      });

      test('missing names the assets the library no longer holds', () async {
        final album = await allMedia();
        if (album == null || album.count == 0) return;
        final page = await library().page(album.id, offset: 0, limit: 2);
        const gone = LibraryAssetId('mpx-contract-missing-asset');
        final asked = [...page.assets.map((a) => a.id), gone];
        expect(await library().missing(asked), {gone});
        expect(await library().missing(const []), isEmpty);
      });

      test('a video plays in place from its URI; a photo has none', () async {
        final album = await allMedia();
        if (album == null || album.count == 0) return;
        final page = await library().page(album.id, offset: 0, limit: 60);
        for (final asset in page.assets) {
          final uri = await library().playable(asset.id);
          if (asset.kind == LibraryAssetKind.video) {
            expect(uri, isNotNull, reason: '${asset.id} is a video');
          } else {
            expect(uri, isNull, reason: '${asset.id} is a photo');
          }
        }
      });
    });
  }
}
