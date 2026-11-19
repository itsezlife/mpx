import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  late FakeMediaLibrary library;
  late LibraryFetcher fetcher;
  final photo = FakeMediaLibrary.assetAt(0);
  final cloud = FakeMediaLibrary.assetAt(1);

  setUp(() {
    library = FakeMediaLibrary(
      assets: 3,
      cloudHeld: {cloud.id},
      originalDelay: const Duration(milliseconds: 8),
    );
    fetcher = LibraryFetcher(library);
  });
  tearDown(() => library.dispose());

  FetchRequest request(
    MediaDescriptor descriptor,
    FetchPart part, {
    FetchProgress? onProgress,
  }) => FetchRequest(
    descriptor: descriptor,
    part: part,
    priority: AssetPriority.visible,
    cancellation: CancellationToken(),
    onProgress: onProgress ?? (_, _) {},
  );

  test('a thumbnail key fetches the library thumbnail at its size', () async {
    final content = await fetcher.fetch(
      request(LibraryKeys.thumbnailDescriptorOf(photo, 96), FetchPart.content),
    );
    expect(content, isA<FetchedBytes>());
    expect(
      utf8.decode((content as FetchedBytes).bytes),
      'thumbnail ${photo.id.value} 96',
    );
  });

  test('an original is lent as a file and given back on release', () async {
    final content = await fetcher.fetch(
      request(LibraryKeys.descriptorOf(photo), FetchPart.content),
    );
    expect(content, isA<FetchedFile>());
    expect(File((content as FetchedFile).path).existsSync(), isTrue);
    expect(library.openLeases, 1);
    content.release();
    await pumpEventQueue();
    expect(library.openLeases, 0);
  });

  test('a cloud-held original needs a download and reports it', () async {
    expect(fetcher.needsDownload(LibraryKeys.libraryKeyOf(cloud)), isTrue);
    expect(fetcher.needsDownload(LibraryKeys.libraryKeyOf(photo)), isFalse);
    expect(
      fetcher.needsDownload(LibraryKeys.thumbnailKeyOf(cloud, 96)),
      isFalse,
      reason: 'thumbnails come from the platform thumbnail API',
    );
    final reports = <(int, int?)>[];
    final content = await fetcher.fetch(
      request(
        LibraryKeys.descriptorOf(cloud),
        FetchPart.content,
        onProgress: (received, total) => reports.add((received, total)),
      ),
    );
    expect(reports, isNotEmpty);
    expect(reports.last.$1, reports.last.$2);
    content.release();
  });

  test("the asset's thumbnail part uses the descriptor's size", () async {
    final descriptor = LibraryKeys.descriptorOf(photo, thumbnailPixels: 160);
    final content = await fetcher.fetch(
      request(descriptor, FetchPart.thumbnail),
    );
    expect(
      utf8.decode((content as FetchedBytes).bytes),
      'thumbnail ${photo.id.value} 160',
    );
  });

  test('a missing asset is a permanent failure', () async {
    const gone = LibraryAsset(
      id: LibraryAssetId('gone'),
      kind: LibraryAssetKind.photo,
    );
    await expectLater(
      fetcher.fetch(request(LibraryKeys.descriptorOf(gone), FetchPart.content)),
      throwsA(
        isA<FetchFailure>().having(
          (f) => f.kind,
          'kind',
          AssetFailureKind.permanent,
        ),
      ),
    );
  });

  test('keys that are not library keys are refused', () async {
    expect(LibraryFetcher.handles(const MediaKey.remote('1')), isFalse);
    expect(LibraryFetcher.handles(LibraryKeys.libraryKeyOf(photo)), isTrue);
    await expectLater(
      fetcher.fetch(
        request(
          const MediaDescriptor(key: MediaKey.remote('1')),
          FetchPart.content,
        ),
      ),
      throwsA(isA<FetchFailure>()),
    );
    expect(fetcher.needsDownload(const MediaKey.remote('1')), isFalse);
  });
}
