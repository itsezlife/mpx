import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';

void main() {
  test('a platform without an adapter fails every item unavailable and '
      'releases its leases', () async {
    final diagnostics = RecordingDiagnostics.install();
    var released = 0;
    // Desktop hosts (a Linux CI runner) have an adapter: the platform
    // without one is stood in for.
    final job = PlatformMediaSaver.over(const NoAdapterSaveWriter('test')).save(
      [
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
      ],
      const SaveDestination.downloads(),
    );

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
}
