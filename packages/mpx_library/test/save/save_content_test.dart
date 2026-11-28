import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

const _a = MediaKey.remote('a');
const _b = MediaKey.remote('b');

SaveRequest _photo(MediaKey key) => SaveRequest(
  key,
  name: 'holiday.jpg',
  mimeType: 'image/jpeg',
  kind: SaveItemKind.photo,
);

void main() {
  late FakeTrackedTransfers transfers;
  late RecordingDiagnostics diagnostics;

  setUp(() {
    transfers = FakeTrackedTransfers();
    diagnostics = RecordingDiagnostics.install();
  });

  test('a local item is leased, saved and released, with no '
      'download', () async {
    transfers.setFile(_a, '/cache/a');
    final saver = FakeMediaSaver(transfers: transfers);

    final results = await saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery()).results;

    expect(results.single, isA<SaveResult$Saved>());
    expect(transfers.downloads, isEmpty);
    expect(saver.writes.single.item.path, '/cache/a');
    expect(saver.writes.single.item.name, 'holiday.jpg');
    expect(transfers.leasesHeld, 0);
    expect(diagnostics.whereOp(SaveOp.downloadShared), [
      isMpxEvent(mediaKey: _a, fields: {'index': 0, 'why': 'local'}),
    ]);
  });
  test('a content not local is downloaded by the user, followed, leased, '
      'saved and released', () async {
    final saver = FakeMediaSaver(transfers: transfers, progressSteps: 2);
    final job = saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery());
    final seen = <double>[];
    job.progress.addListener(() => seen.add(job.progress.value));

    await pumpEventQueue();
    expect(transfers.downloads, [(key: _a, origin: TransferOrigin.user)]);
    expect(transfers.isWatched(_a), isTrue);
    transfers.drive(_a, const AssetTransfer.receiving(50, 100));
    expect(job.progress.value, closeTo(0.45, 1e-9));
    transfers
      ..setFile(_a, '/cache/a')
      ..drive(_a, AssetTransfer.none);
    final results = await job.results;

    expect(results.single, isA<SaveResult$Saved>());
    expect(saver.writes.single.item.path, '/cache/a');
    expect(saver.writes.single.item.isLeased, isTrue);
    expect(transfers.leasesHeld, 0);
    expect(transfers.isWatched(_a), isFalse);
    expect(seen, [
      closeTo(0.45, 1e-9),
      closeTo(0.9, 1e-9),
      closeTo(0.95, 1e-9),
      1.0,
    ]);
    expect(diagnostics.whereOp(SaveOp.downloadStarted), [
      isMpxEvent(
        jobId: job.id,
        mediaKey: _a,
        fields: {'index': 0, 'origin': 'user'},
      ),
    ]);
    expect(diagnostics.whereOp(SaveOp.progress).map((e) => e.fields['stage']), [
      'download',
      'download',
      'copy',
      'copy',
    ]);
    expect(diagnostics.whereOp(SaveOp.itemSaved), [
      isMpxEvent(mediaKey: _a, fields: containsPair('index', 0)),
    ]);
    expect(diagnostics.whereOp(SaveOp.leaseReleased), [
      isMpxEvent(mediaKey: _a, fields: {'index': 0, 'after': 'saved'}),
    ]);
  });

  test('an item already local counts its copy as its whole share', () async {
    transfers.setFile(_a, '/cache/a');
    final saver = FakeMediaSaver(transfers: transfers, progressSteps: 2);
    final job = saver.saveContent([
      _photo(_a),
      _photo(_b),
    ], const SaveDestination.gallery());
    final seen = <double>[];
    job.progress.addListener(() => seen.add(job.progress.value));

    await pumpEventQueue();
    transfers.drive(_b, const AssetTransfer.receiving(1, 2));
    // b's download half done: 0.45 of its share, a's copy not begun.
    expect(job.progress.value, closeTo(0.225, 1e-9));
    transfers
      ..setFile(_b, '/cache/b')
      ..drive(_b, AssetTransfer.none);
    await job.results;

    // a's copy: two steps of its whole share; b's copy: two steps of 10 %.
    expect(seen, [
      closeTo(0.225, 1e-9),
      closeTo(0.45, 1e-9),
      closeTo(0.7, 1e-9),
      closeTo(0.95, 1e-9),
      closeTo(0.975, 1e-9),
      1.0,
    ]);
  });

  test('a cancel stops the downloads the job started and leaves another '
      'caller\'s running', () async {
    // Someone else's download of b is under way before the save.
    transfers.drive(_b, const AssetTransfer.receiving(10, 100));
    final saver = FakeMediaSaver(transfers: transfers);
    final job = saver.saveContent([
      _photo(_a),
      _photo(_b),
    ], const SaveDestination.gallery());

    await pumpEventQueue();
    expect(transfers.downloads.map((d) => d.key), [_a, _b]);
    job.cancel();
    final results = await job.results;

    expect(results, [
      const SaveResult.cancelled(),
      const SaveResult.cancelled(),
    ]);
    expect(transfers.cancels, [_a]);
    expect(transfers.valueOf(_b), const AssetTransfer.receiving(10, 100));
    expect(saver.writes, isEmpty);
    expect(job.progress.value, 1);
    expect(diagnostics.whereOp(SaveOp.downloadShared), [
      isMpxEvent(mediaKey: _b, fields: {'index': 1, 'why': 'other'}),
    ]);
    expect(diagnostics.whereOp(SaveOp.downloadsCancelled), [
      isMpxEvent(jobId: job.id, fields: {'own': 1, 'shared': 1}),
    ]);
    expect(diagnostics.whereOp(SaveOp.itemCancelled), [
      isMpxEvent(mediaKey: _a, fields: {'index': 0, 'stage': 'download'}),
      isMpxEvent(mediaKey: _b, fields: {'index': 1, 'stage': 'download'}),
    ]);
  });

  test('a cancel once the content is local releases its lease', () async {
    transfers.setFile(_a, '/cache/a');
    final saver = FakeMediaSaver(transfers: transfers, progressSteps: 4);
    final job = saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery());
    job.progress.addListener(() {
      if (job.progress.value >= 0.5) job.cancel();
    });

    expect(await job.results, [const SaveResult.cancelled()]);
    expect(transfers.leasesHeld, 0);
    expect(transfers.cancels, isEmpty);
    expect(diagnostics.whereOp(SaveOp.downloadsCancelled), isEmpty);
    expect(diagnostics.whereOp(SaveOp.leaseReleased), [
      isMpxEvent(mediaKey: _a, fields: {'index': 0, 'after': 'cancelled'}),
    ]);
  });

  test('a lease missing after a completed download downloads once more, '
      'then fails unavailable', () async {
    final saver = FakeMediaSaver(transfers: transfers);
    final job = saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery());

    await pumpEventQueue();
    transfers.drive(_a, AssetTransfer.none);
    await pumpEventQueue();
    expect(transfers.downloads, hasLength(2));
    transfers.drive(_a, AssetTransfer.none);
    final results = await job.results;

    expect(results, [
      const SaveResult.failed(SaveFailure.unavailable, code: 'noLease'),
    ]);
    expect(saver.writes, isEmpty);
    expect(diagnostics.whereOp(SaveOp.leaseMissing), [
      isMpxEvent(
        level: MpxEventLevel.warning,
        mediaKey: _a,
        fields: {'index': 0, 'attempt': 1},
      ),
      isMpxEvent(mediaKey: _a, fields: {'index': 0, 'attempt': 2}),
    ]);
    expect(diagnostics.whereOp(SaveOp.itemFailed), [
      isMpxEvent(
        mediaKey: _a,
        fields: {'index': 0, 'reason': 'unavailable', 'code': 'noLease'},
      ),
    ]);
  });

  test('a second download that brings the file saves it', () async {
    final saver = FakeMediaSaver(transfers: transfers);
    final job = saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery());

    await pumpEventQueue();
    transfers.drive(_a, AssetTransfer.none);
    await pumpEventQueue();
    transfers
      ..setFile(_a, '/cache/a')
      ..drive(_a, AssetTransfer.none);

    expect((await job.results).single, isA<SaveResult$Saved>());
    expect(diagnostics.whereOp(SaveOp.leaseMissing), hasLength(1));
    expect(transfers.leasesHeld, 0);
  });

  test('a failed download fails its item unavailable', () async {
    final saver = FakeMediaSaver(transfers: transfers);
    final job = saver.saveContent([
      _photo(_a),
    ], const SaveDestination.gallery());

    await pumpEventQueue();
    transfers.drive(_a, const AssetTransfer.failed(AssetFailureKind.transient));

    expect(await job.results, [
      const SaveResult.failed(SaveFailure.unavailable, code: 'download'),
    ]);
    expect(transfers.isWatched(_a), isFalse);
  });

  test('without tracked transfers every item fails unavailable, with a '
      'warning', () async {
    final saver = FakeMediaSaver();
    final job = saver.saveContent([
      _photo(_a),
      _photo(_b),
    ], const SaveDestination.gallery());

    expect(
      await job.results,
      everyElement(
        const SaveResult.failed(
          SaveFailure.unavailable,
          code: 'noTrackedTransfers',
        ),
      ),
    );
    expect(saver.writes, isEmpty);
    expect(diagnostics.whereOp(SaveOp.trackedTransfersMissing), [
      isMpxEvent(
        level: MpxEventLevel.warning,
        jobId: job.id,
        fields: {'items': 2},
      ),
    ]);
  });

  test('denied access fails every item before any lease or download', () async {
    transfers.setFile(_a, '/cache/a');
    final saver = FakeMediaSaver(transfers: transfers)
      ..saveAccess = SaveAccess.denied;
    final results = await saver.saveContent([
      _photo(_a),
      _photo(_b),
    ], const SaveDestination.gallery()).results;

    expect(
      results,
      everyElement(const SaveResult.failed(SaveFailure.accessDenied)),
    );
    expect(transfers.leaseRequests, isEmpty);
    expect(transfers.downloads, isEmpty);
    expect(diagnostics.whereOp(SaveOp.downloadStarted), isEmpty);
  });

  test('the request names, files and dates the item; no event carries '
      'its name or path', () async {
    transfers.setFile(_a, '/secret/cache/a');
    final saver = FakeMediaSaver(transfers: transfers);
    final created = DateTime.utc(2026);
    await saver.saveContent([
      SaveRequest(
        _a,
        name: 'secret.pdf',
        mimeType: 'application/pdf',
        kind: SaveItemKind.file,
        createdAt: created,
      ),
    ], const SaveDestination.downloads()).results;

    final item = saver.writes.single.item;
    expect(item.name, 'secret.pdf');
    expect(item.mimeType, 'application/pdf');
    expect(item.kind, SaveItemKind.file);
    expect(item.createdAt, created);
    expect(saver.contentBatches.single.requests.single.key, _a);
    for (final event in diagnostics.whereCategory('save')) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('secret')));
      }
    }
  });
}
