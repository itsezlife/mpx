import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  late FakeMediaLibrary library;
  late LibraryPages pages;

  setUp(() async {
    library = FakeMediaLibrary(assets: 100);
    final album = (await library.albums()).single;
    pages = LibraryPages(library: library, album: album, pageSize: 10);
  });

  tearDown(() async {
    pages.dispose();
    await library.dispose();
  });

  Future<void> load(int index) async {
    pages.assetAt(index);
    await pumpEventQueue();
  }

  test('a reload keeps the pages read until their fresh read lands', () async {
    await load(0);
    final before = pages.assetAt(3);
    expect(before, isNotNull);

    pages.reload();
    // Asked again, the page answers what it held while it reads afresh.
    expect(pages.assetAt(3), before);
    final reads = pages.pageReads;
    await pumpEventQueue();
    expect(pages.pageReads, reads + 1);
    expect(pages.assetAt(3), before);
  });

  test('a reload after a change lands the change in place', () async {
    await load(0);
    library.insert([
      const LibraryAsset(
        id: LibraryAssetId('fresh'),
        kind: LibraryAssetKind.photo,
      ),
    ]);
    pages.reload();
    expect(pages.assetAt(0)?.id, FakeMediaLibrary.assetAt(0).id);
    await pumpEventQueue();
    expect(pages.assetAt(0)?.id, const LibraryAssetId('fresh'));
    expect(pages.total, 101);
  });

  test('a fresh read that changes nothing does not notify', () async {
    await load(0);
    var notified = 0;
    pages.addListener(() => notified++);
    pages.reload();
    pages.assetAt(0);
    await pumpEventQueue();
    expect(notified, 1);
  });

  test('nearestAt answers the asset when its page is in, else the nearest '
      'asset held, and asks for the page', () async {
    expect(pages.nearestAt(5), isNull);
    await load(0);
    expect(pages.nearestAt(5)?.id, FakeMediaLibrary.assetAt(5).id);
    // Page 5 (assets 50-59) is not in: the last asset of page 0 stands in.
    expect(pages.nearestAt(55)?.id, FakeMediaLibrary.assetAt(9).id);
    await pumpEventQueue();
    expect(pages.nearestAt(55)?.id, FakeMediaLibrary.assetAt(55).id);
    // Below page 5 now, the first held asset after it stands in.
    expect(pages.nearestAt(30)?.id, FakeMediaLibrary.assetAt(50).id);
    expect(pages.nearestAt(-1), isNull);
    expect(pages.nearestAt(100), isNull);
  });
}
