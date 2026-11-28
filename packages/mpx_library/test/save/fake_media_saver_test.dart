import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

SaveItem _photo(int index, {bool move = false}) => SaveItem.file(
  '/host/photo-$index.jpg',
  name: 'photo-$index.jpg',
  mimeType: 'image/jpeg',
  kind: SaveItemKind.photo,
  move: move,
);

SaveItem _file(String mimeType) => SaveItem.file(
  '/host/file',
  name: 'file',
  mimeType: mimeType,
  kind: SaveItemKind.file,
);

final class _Lender {
  int released = 0;

  ContentFileLease lend(String path) =>
      ContentFileLease(path: path, onRelease: () async => released++);

  SaveItem leased(int index, {bool move = false}) => SaveItem.leased(
    lend('/cache/blob-$index'),
    name: 'photo-$index.jpg',
    mimeType: 'image/jpeg',
    kind: SaveItemKind.photo,
    move: move,
  );
}

void main() {
  test('a batch is one recorded job with a result per item', () async {
    final saver = FakeMediaSaver();
    final job = saver.save([
      _photo(0),
      _photo(1),
    ], const SaveDestination.gallery());

    final results = await job.results;
    expect(results, hasLength(2));
    expect(results.every((r) => r.isSaved), isTrue);
    expect(saver.batches, hasLength(1));
    expect(saver.batches.single.jobId, job.id);
    expect(saver.batches.single.items, hasLength(2));
    expect(saver.batches.single.destination, const SaveDestination.gallery());
  });

  test('progress climbs in steps over the batch and ends at 1', () async {
    final saver = FakeMediaSaver(progressSteps: 2);
    final job = saver.save([
      _photo(0),
      _photo(1),
    ], const SaveDestination.downloads());
    final seen = <double>[];
    job.progress.addListener(() => seen.add(job.progress.value));

    await job.results;
    expect(seen, [0.25, 0.5, 0.75, 1.0]);
  });

  test('a cancel during the second item keeps the first saved and cancels '
      'the rest', () async {
    final saver = FakeMediaSaver(progressSteps: 2);
    final job = saver.save([
      _photo(0),
      _photo(1),
      _photo(2),
    ], const SaveDestination.gallery());
    job.progress.addListener(() {
      // Each item is a third, in two steps: past a third is inside item 1.
      if (job.progress.value > 0.34) job.cancel();
    });

    final results = await job.results;
    expect(results[0].isSaved, isTrue);
    expect(results[1], const SaveResult.cancelled());
    expect(results[2], const SaveResult.cancelled());
    expect(job.progress.value, 1);
    expect(saver.writes.map((w) => w.index), [0, 1]);
  });

  test('a cancel right after save cancels every item', () async {
    final saver = FakeMediaSaver();
    final job = saver.save([_photo(0), _photo(1)], const SaveDestination.ask())
      ..cancel();

    expect(await job.results, [
      const SaveResult.cancelled(),
      const SaveResult.cancelled(),
    ]);
    expect(saver.writes, isEmpty);
  });

  group('a file sent to the gallery', () {
    test('goes as a photo or a video by its MIME type', () async {
      final saver = FakeMediaSaver();
      final results = await saver.save([
        _file('image/png'),
        _file('video/mp4'),
      ], const SaveDestination.gallery()).results;

      expect(results.every((r) => r.isSaved), isTrue);
      expect(saver.writes.map((w) => w.kind), [
        SaveItemKind.photo,
        SaveItemKind.video,
      ]);
    });

    test('fails unsupportedFormat when it is neither, and is not '
        'written', () async {
      final saver = FakeMediaSaver();
      final results = await saver.save([
        _file('application/pdf'),
        _photo(1),
      ], const SaveDestination.gallery()).results;

      expect(
        results[0],
        const SaveResult.failed(SaveFailure.unsupportedFormat),
      );
      expect(results[1].isSaved, isTrue);
      expect(saver.writes.map((w) => w.index), [1]);
    });

    test('stays a file in Downloads', () async {
      final saver = FakeMediaSaver();
      await saver.save([
        _file('application/pdf'),
      ], const SaveDestination.downloads()).results;

      expect(saver.writes.single.kind, SaveItemKind.file);
    });
  });

  test('a leased file is copied even when move is asked; a host file '
      'moves', () async {
    final saver = FakeMediaSaver();
    final lender = _Lender();
    final results = await saver.save([
      lender.leased(0, move: true),
      _photo(1, move: true),
    ], const SaveDestination.gallery()).results;

    expect(results.every((r) => r.isSaved), isTrue);
    expect(saver.writes.map((w) => w.move), [false, true]);
  });

  group('a lease is released once its item is done', () {
    test('saved', () async {
      final lender = _Lender();
      await FakeMediaSaver().save([
        lender.leased(0),
        lender.leased(1),
      ], const SaveDestination.gallery()).results;
      expect(lender.released, 2);
    });

    test('failed by the platform or by routing', () async {
      final lender = _Lender();
      final saver = FakeMediaSaver(
        resultFor: (_) => const SaveResult.failed(SaveFailure.noSpace),
      );
      final results = await saver.save([
        lender.leased(0),
        SaveItem.leased(
          lender.lend('/cache/doc'),
          name: 'doc',
          mimeType: 'application/pdf',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.gallery()).results;
      expect(results, [
        const SaveResult.failed(SaveFailure.noSpace),
        const SaveResult.failed(SaveFailure.unsupportedFormat),
      ]);
      expect(lender.released, 2);
    });

    test('cancelled before or during its write', () async {
      final lender = _Lender();
      final job = FakeMediaSaver(progressSteps: 2).save([
        lender.leased(0),
        lender.leased(1),
      ], const SaveDestination.gallery());
      job.progress.addListener(() {
        if (job.progress.value > 0) job.cancel();
      });
      expect(await job.results, [
        const SaveResult.cancelled(),
        const SaveResult.cancelled(),
      ]);
      expect(lender.released, 2);
    });

    test('refused for denied access', () async {
      final lender = _Lender();
      final saver = FakeMediaSaver()..saveAccess = SaveAccess.denied;
      await saver.save([
        lender.leased(0),
      ], const SaveDestination.gallery()).results;
      expect(lender.released, 1);
    });
  });

  test('denied access fails every item accessDenied and writes '
      'nothing', () async {
    final saver = FakeMediaSaver()..saveAccess = SaveAccess.denied;
    final results = await saver.save([
      _photo(0),
      _photo(1),
    ], const SaveDestination.gallery()).results;

    expect(results, [
      const SaveResult.failed(SaveFailure.accessDenied),
      const SaveResult.failed(SaveFailure.accessDenied),
    ]);
    expect(saver.writes, isEmpty);
  });

  group('save access', () {
    test('a batch asks once while not determined, then saves', () async {
      final diagnostics = RecordingDiagnostics.install();
      final saver = FakeMediaSaver()..saveAccess = SaveAccess.notDetermined;

      final job = saver.save([_photo(0)], const SaveDestination.gallery());
      expect(await job.results, [isA<SaveResult$Saved>()]);
      await saver.save([_photo(1)], const SaveDestination.gallery()).results;

      expect(saver.accessRequests, 1);
      expect(
        await saver.access(const SaveDestination.gallery()),
        SaveAccess.granted,
      );
      expect(diagnostics.whereOp(SaveOp.accessRequested), [
        isMpxEvent(
          jobId: job.id,
          fields: {'access': 'addOnly', 'result': 'granted'},
        ),
      ]);
    });

    test('a refused prompt fails every item accessDenied', () async {
      final saver = FakeMediaSaver()
        ..saveAccess = SaveAccess.notDetermined
        ..grantOnRequest = SaveAccess.denied;

      final results = await saver.save([
        _photo(0),
        _photo(1),
      ], const SaveDestination.gallery()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.accessDenied),
        const SaveResult.failed(SaveFailure.accessDenied),
      ]);
      expect(saver.writes, isEmpty);
    });

    test('a host asks ahead; asking again shows no prompt', () async {
      final saver = FakeMediaSaver()..saveAccess = SaveAccess.notDetermined;

      expect(
        await saver.requestAccess(const SaveDestination.gallery()),
        SaveAccess.granted,
      );
      expect(
        await saver.requestAccess(const SaveDestination.gallery()),
        SaveAccess.granted,
      );
      expect(saver.accessRequests, 1);
    });

    test('a restricted access is refused without a prompt', () async {
      final saver = FakeMediaSaver()..saveAccess = SaveAccess.restricted;

      final results = await saver.save([
        _photo(0),
      ], const SaveDestination.gallery()).results;

      expect(results, [const SaveResult.failed(SaveFailure.accessDenied)]);
      expect(saver.accessRequests, 0);
    });

    test(
      'a build without the save code fails every item unavailable',
      () async {
        final diagnostics = RecordingDiagnostics.install();
        final saver = FakeMediaSaver()..saveAccess = SaveAccess.unavailable;

        final job = saver.save([
          _photo(0),
        ], const SaveDestination.gallery(album: 'Trips'));

        expect(await job.results, [
          const SaveResult.failed(
            SaveFailure.unavailable,
            code: 'defineMissing',
          ),
        ]);
        expect(diagnostics.whereOp(SaveOp.defineMissing), [
          isMpxEvent(
            jobId: job.id,
            fields: {
              'destination': 'gallery',
              'named': true,
              'define': 'MPX_LIBRARY_SAVE',
            },
          ),
        ]);
      },
    );
  });

  group('one change block per batch', () {
    test('a failed block fails every item', () async {
      final saver = FakeMediaSaver(changeBlock: true)
        ..blockFailure = SaveFailure.noSpace;
      final results = await saver.save([
        _photo(0),
        _photo(1),
      ], const SaveDestination.gallery()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.noSpace),
        const SaveResult.failed(SaveFailure.noSpace),
      ]);
    });

    test('a cancel before the block cancels every item', () async {
      final saver = FakeMediaSaver(changeBlock: true);
      final job = saver.save([
        _photo(0),
        _photo(1),
      ], const SaveDestination.gallery())..cancel();

      expect(await job.results, [
        const SaveResult.cancelled(),
        const SaveResult.cancelled(),
      ]);
      expect(saver.writes, isEmpty);
    });

    test('a cancel during the block has no effect', () async {
      final saver = FakeMediaSaver(changeBlock: true, progressSteps: 4);
      final job = saver.save([
        _photo(0),
        _photo(1),
      ], const SaveDestination.gallery());
      job.progress.addListener(() {
        if (job.progress.value > 0) job.cancel();
      });

      final results = await job.results;
      expect(results.every((r) => r.isSaved), isTrue);
      expect(saver.writes, hasLength(2));
    });

    test('one failed item in the block fails every item', () async {
      final saver = FakeMediaSaver(
        changeBlock: true,
        resultFor: (write) => write.index == 1
            ? const SaveResult.failed(SaveFailure.unsupportedFormat)
            : const SaveResult.saved('asset'),
      );
      final results = await saver.save([
        _photo(0),
        _photo(1),
      ], const SaveDestination.gallery()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.unsupportedFormat),
        const SaveResult.failed(SaveFailure.unsupportedFormat),
      ]);
    });
  });
}
