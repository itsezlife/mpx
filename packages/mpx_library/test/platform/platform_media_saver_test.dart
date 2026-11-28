import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';

void main() {
  test('a platform without an adapter fails every item unavailable and '
      'releases its leases', () async {
    final diagnostics = RecordingDiagnostics.install();
    var released = 0;
    final job = PlatformMediaSaver().save([
      SaveItem.leased(
        ContentFileLease(path: '/cache/a', onRelease: () async => released++),
        name: 'a.jpg',
        mimeType: 'image/jpeg',
        kind: SaveItemKind.photo,
      ),
      const SaveItem.file(
        '/host/b.mp4',
        name: 'b.mp4',
        mimeType: 'video/mp4',
        kind: SaveItemKind.video,
      ),
    ], const SaveDestination.downloads());

    const unavailable = SaveResult.failed(
      SaveFailure.unavailable,
      code: 'noAdapter',
    );
    expect(await job.results, [unavailable, unavailable]);
    expect(job.progress.value, 1);
    expect(released, 1);
    expect(diagnostics.whereOp(SaveOp.jobStarted), [
      isMpxEvent(fields: containsPair('platform', isNotEmpty)),
    ]);
    expect(
      diagnostics.whereOp(SaveOp.itemFailed).map((e) => e.fields['code']),
      ['noAdapter', 'noAdapter'],
    );
  });

  test('saveContent goes through the transfers it was given', () async {
    RecordingDiagnostics.install();
    const key = MediaKey.remote('a');
    final transfers = FakeTrackedTransfers()..setFile(key, '/cache/a');
    const request = SaveRequest(
      key,
      name: 'a.jpg',
      mimeType: 'image/jpeg',
      kind: SaveItemKind.photo,
    );

    final withTransfers = PlatformMediaSaver(transfers: transfers);
    expect(
      await withTransfers.saveContent([
        request,
      ], const SaveDestination.gallery()).results,
      [const SaveResult.failed(SaveFailure.unavailable, code: 'noAdapter')],
    );
    expect(transfers.leaseRequests, [key]);
    expect(transfers.leasesHeld, 0);

    expect(
      await PlatformMediaSaver().saveContent([
        request,
      ], const SaveDestination.gallery()).results,
      [
        const SaveResult.failed(
          SaveFailure.unavailable,
          code: 'noTrackedTransfers',
        ),
      ],
    );
  });
}
