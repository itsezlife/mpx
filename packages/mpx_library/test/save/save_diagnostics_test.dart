import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  late RecordingDiagnostics diagnostics;

  setUp(() => diagnostics = RecordingDiagnostics.install());

  SaveItem photo({bool move = false, ContentFileLease? lease}) => lease == null
      ? SaveItem.file(
          '/secret/holiday.jpg',
          name: 'holiday.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
          move: move,
        )
      : SaveItem.leased(
          lease,
          name: 'holiday.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
          move: move,
        );

  test(
    'a batch reports its start, items and finish under its job id',
    () async {
      final job = FakeMediaSaver(progressSteps: 1, stepBytes: 300).save([
        photo(),
        const SaveItem.file(
          '/secret/notes.pdf',
          name: 'notes.pdf',
          mimeType: 'application/pdf',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.gallery(album: 'Secret album'));
      await job.results;

      final events = diagnostics.whereCategory('save');
      expect(events.every((e) => e.jobId == job.id), isTrue);
      expect(diagnostics.whereOp(SaveOp.jobStarted), [
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {
            'items': 2,
            'destination': 'gallery',
            'named': true,
            'platform': 'fake',
            'photos': 1,
            'videos': 0,
            'animations': 0,
            'files': 1,
          },
        ),
      ]);
      expect(diagnostics.whereOp(SaveOp.routedByMime), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          fields: {'index': 1, 'mime': 'other', 'outcome': 'unsupportedFormat'},
        ),
      ]);
      expect(diagnostics.whereOp(SaveOp.itemSaved), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          fields: allOf(
            containsPair('index', 0),
            containsPair('kind', 'photo'),
            containsPair('mime', 'image'),
            containsPair('bytes', 300),
            containsPair('renamed', false),
            contains('ms'),
          ),
        ),
      ]);
      expect(diagnostics.whereOp(SaveOp.itemFailed), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {'index': 1, 'reason': 'unsupportedFormat'},
        ),
      ]);
      expect(diagnostics.whereOp(SaveOp.progress), isNotEmpty);
      expect(
        diagnostics.whereOp(SaveOp.progress).last,
        isMpxEvent(
          level: MpxEventLevel.trace,
          fields: {'fraction': 1.0, 'stage': 'copy'},
        ),
      );
      expect(diagnostics.whereOp(SaveOp.jobFinished), [
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: allOf(
            containsPair('saved', 1),
            containsPair('cancelled', 0),
            containsPair('failed', 1),
            contains('ms'),
          ),
        ),
      ]);
      expect(events.last.op, SaveOp.jobFinished);

      for (final event in diagnostics.events) {
        for (final value in event.fields.values) {
          expect(
            '$value',
            isNot(anyOf(contains('secret'), contains('Secret'), contains('/'))),
            reason: 'no name, path or album in ${event.op.name}',
          );
        }
      }
    },
  );

  test('a platform error code and a cancel are reported per item', () async {
    final job = FakeMediaSaver(
      resultFor: (write) =>
          const SaveResult.failed(SaveFailure.noSpace, code: 'ENOSPC'),
      progressSteps: 2,
    ).save([photo(), photo()], const SaveDestination.downloads());
    job.progress.addListener(() {
      if (job.progress.value > 0.5) job.cancel();
    });
    await job.results;

    expect(diagnostics.whereOp(SaveOp.itemFailed), [
      isMpxEvent(fields: {'index': 0, 'reason': 'noSpace', 'code': 'ENOSPC'}),
    ]);
    expect(diagnostics.whereOp(SaveOp.itemCancelled), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        fields: {'index': 1, 'stage': 'copy'},
      ),
    ]);
  });

  test('a move asked for a leased file is refused with a warning', () async {
    final lease = ContentFileLease(path: '/cache/x', onRelease: () async {});
    await FakeMediaSaver().save([
      photo(move: true, lease: lease),
    ], const SaveDestination.gallery()).results;

    expect(diagnostics.whereOp(SaveOp.moveRefused), [
      isMpxEvent(level: MpxEventLevel.warning, fields: {'index': 0}),
    ]);
    expect(diagnostics.whereOp(SaveOp.leaseReleased), [
      isMpxEvent(
        level: MpxEventLevel.trace,
        fields: {'index': 0, 'after': 'saved'},
      ),
    ]);
  });

  test('denied access is one failure per item', () async {
    await (FakeMediaSaver()..accessDenied = true).save([
      photo(),
      photo(),
    ], const SaveDestination.gallery()).results;

    expect(
      diagnostics.whereOp(SaveOp.itemFailed).map((e) => e.fields['reason']),
      ['accessDenied', 'accessDenied'],
    );
  });
}
