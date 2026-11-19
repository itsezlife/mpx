import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  late FakeMediaLibrary library;

  setUp(() => library = FakeMediaLibrary(assets: 10));
  tearDown(() => library.dispose());

  test('generated assets fill the all-media album newest first', () async {
    final album = (await library.albums()).single;
    expect(album.kind, LibraryAlbumKind.allMedia);
    expect(album.count, 10);
    expect(album.cover, FakeMediaLibrary.assetAt(0));
    final page = await library.page(album.id, offset: 0, limit: 10);
    expect(page.assets, [
      for (var i = 0; i < 10; i++) FakeMediaLibrary.assetAt(i),
    ]);
    final created = page.assets.map((a) => a.created!).toList();
    for (var i = 1; i < created.length; i++) {
      expect(created[i].isBefore(created[i - 1]), isTrue);
    }
    expect(
      page.assets.where((a) => a.kind == LibraryAssetKind.video),
      isNotEmpty,
    );
  });

  test('an added album lists after the all-media album', () async {
    library.addAlbum(
      const LibraryAlbumId('camera'),
      kind: LibraryAlbumKind.camera,
      title: 'Camera',
      assets: [FakeMediaLibrary.assetAt(3).id, FakeMediaLibrary.assetAt(5).id],
    );
    final albums = await library.albums();
    expect(albums.map((a) => a.id.value), ['all', 'camera']);
    expect(albums.last.count, 2);
    final page = await library.page(albums.last.id, offset: 0, limit: 5);
    expect(page.assets.map((a) => a.id), [
      FakeMediaLibrary.assetAt(3).id,
      FakeMediaLibrary.assetAt(5).id,
    ]);
  });

  test('scripted access transitions notify', () {
    final seen = <LibraryAccess>[];
    library.access.addListener(() => seen.add(library.access.value));
    library
      ..setAccess(LibraryAccess.limited)
      ..setAccess(LibraryAccess.limited)
      ..setAccess(LibraryAccess.denied);
    expect(seen, [LibraryAccess.limited, LibraryAccess.denied]);
  });

  test('requestAccess grants the scripted access once', () async {
    final asking = FakeMediaLibrary(
      access: LibraryAccess.notDetermined,
      grantOnRequest: LibraryAccess.partial,
    );
    addTearDown(asking.dispose);
    expect(await asking.requestAccess(), LibraryAccess.partial);
    asking.setAccess(LibraryAccess.denied);
    expect(await asking.requestAccess(), LibraryAccess.denied);
    expect(asking.requestAccessCalls, 2);
  });

  test('manageSelected asks only under limited or partial', () async {
    expect(await library.manageSelected(), isFalse);
    library.setAccess(LibraryAccess.limited);
    expect(await library.manageSelected(), isTrue);
    library.setAccess(LibraryAccess.partial);
    expect(await library.manageSelected(), isTrue);
    expect(library.manageSelectedCalls, 2);
  });

  test('an insert emits a change and later pages reflect it', () async {
    final events = <LibraryChange>[];
    library.changes.listen(events.add);
    final before = await library.page(
      const LibraryAlbumId('all'),
      offset: 0,
      limit: 3,
    );
    const fresh = LibraryAsset(
      id: LibraryAssetId('fresh'),
      kind: LibraryAssetKind.photo,
    );
    library.insert([fresh]);
    await pumpEventQueue();
    expect(events, [
      const LibraryChange.album(
        LibraryAlbumId('all'),
        inserted: {LibraryAssetId('fresh')},
      ),
    ]);
    final after = await library.page(
      const LibraryAlbumId('all'),
      offset: 0,
      limit: 3,
    );
    expect(after.assets.first, fresh);
    expect(after.assets.skip(1), before.assets.take(2));
    expect(after.total, 11);
  });

  test('a removal emits a change per album it touches', () async {
    library.addAlbum(
      const LibraryAlbumId('camera'),
      kind: LibraryAlbumKind.camera,
      title: 'Camera',
      assets: [FakeMediaLibrary.assetAt(1).id],
    );
    final events = <LibraryChange>[];
    library.changes.listen(events.add);
    library.remove({FakeMediaLibrary.assetAt(1).id});
    await pumpEventQueue();
    expect(events, hasLength(2));
    final camera = await library.page(
      const LibraryAlbumId('camera'),
      offset: 0,
      limit: 5,
    );
    expect(camera.assets, isEmpty);
  });

  test('a cloud-held original reports its download before it is '
      'lent', () async {
    final slow = FakeMediaLibrary(
      assets: 2,
      cloudHeld: {FakeMediaLibrary.assetAt(1).id},
      originalDelay: const Duration(milliseconds: 20),
    );
    addTearDown(slow.dispose);
    expect(slow.isCloudHeld(FakeMediaLibrary.assetAt(1).id), isTrue);
    expect(slow.isCloudHeld(FakeMediaLibrary.assetAt(0).id), isFalse);

    final reports = <(int, int?)>[];
    final lease = await slow.original(
      FakeMediaLibrary.assetAt(1).id,
      onProgress: (received, total) => reports.add((received, total)),
    );
    expect(reports.first.$1, 0);
    expect(reports.last.$1, reports.last.$2);
    expect(slow.openLeases, 1);
    await lease.release();
    expect(slow.openLeases, 0);

    final local = <(int, int?)>[];
    final localLease = await slow.original(
      FakeMediaLibrary.assetAt(0).id,
      onProgress: (received, total) => local.add((received, total)),
    );
    expect(local, isEmpty, reason: 'a local original is no transfer');
    expect(File(localLease.path).readAsStringSync(), contains('asset-0'));
    await localLease.release();
  });

  test('a cancelled download fails and lends nothing', () async {
    final slow = FakeMediaLibrary(
      assets: 1,
      cloudHeld: {FakeMediaLibrary.assetAt(0).id},
      originalDelay: const Duration(milliseconds: 50),
    );
    addTearDown(slow.dispose);
    final token = CancellationToken();
    final lease = slow.original(
      FakeMediaLibrary.assetAt(0).id,
      cancellation: token,
    );
    token.cancel();
    await expectLater(lease, throwsA(isA<LibraryDownloadFailed>()));
    expect(slow.openLeases, 0);
  });

  test('thumbnails differ per size and asset', () async {
    final a = await library.thumbnail(
      FakeMediaLibrary.assetAt(0).id,
      pixels: 96,
    );
    final b = await library.thumbnail(
      FakeMediaLibrary.assetAt(0).id,
      pixels: 320,
    );
    final c = await library.thumbnail(
      FakeMediaLibrary.assetAt(1).id,
      pixels: 96,
    );
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(library.thumbnailRequests, [
      (FakeMediaLibrary.assetAt(0).id, 96),
      (FakeMediaLibrary.assetAt(0).id, 320),
      (FakeMediaLibrary.assetAt(1).id, 96),
    ]);
  });

  test('without read access the assets are unavailable', () async {
    library.setAccess(LibraryAccess.denied);
    expect(await library.albums(), isEmpty);
    await expectLater(
      library.thumbnail(FakeMediaLibrary.assetAt(0).id, pixels: 96),
      throwsA(isA<LibraryAssetUnavailable>()),
    );
    unawaited(library.openSettings());
    expect(library.openSettingsCalls, 1);
  });
}
