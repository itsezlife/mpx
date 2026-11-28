import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_result.dart';

/// What a [MediaSaver] contract run needs.
final class MediaSaverHarness {
  /// Creates a harness over [saver].
  ///
  /// [file] gives the path of a fresh source file for the [index]th item of
  /// a batch: a photo the platform can save. The contract saves to
  /// [destination] (the gallery by default).
  ///
  /// [changeBlock] declares that the saver writes a batch as one atomic
  /// block (Photos on Apple); the contract then checks the block rules in
  /// place of the per-item cancel. [denyAccess] puts the saver in the state
  /// of refused access, and [failBlock] makes its next block fail; a test
  /// that needs one the harness lacks is skipped.
  ///
  /// With [bytes] the contract's photos are `SaveItem.bytes` items of it,
  /// the web's and in-memory content's fallback, in place of files at
  /// [file]; leased items still lend a file at [file].
  const MediaSaverHarness({
    required this.saver,
    required this.file,
    this.bytes,
    this.destination = const SaveDestination.gallery(),
    this.changeBlock = false,
    this.denyAccess,
    this.failBlock,
  });

  /// The saver under test, fresh for each test.
  final MediaSaver saver;

  /// A fresh source file for item [index].
  final String Function(int index) file;

  /// The content of item [index], when the contract saves bytes.
  final Uint8List Function(int index)? bytes;

  /// Where the contract saves.
  final SaveDestination destination;

  /// Whether a batch is one atomic block.
  final bool changeBlock;

  /// Refuses the access saving needs.
  final void Function()? denyAccess;

  /// Fails the saver's next block, under [changeBlock].
  final void Function()? failBlock;
}

/// The contract every [MediaSaver] meets; see its documentation.
///
/// Each test installs a `RecordingDiagnostics` and restores the policy after
/// it.
abstract final class MediaSaverContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(MediaSaverHarness Function() create) {
    group('MediaSaver contract', () {
      late MediaSaverHarness harness;
      late RecordingDiagnostics diagnostics;

      setUp(() {
        harness = create();
        diagnostics = RecordingDiagnostics.install();
      });

      SaveItem photo(int index) => switch (harness.bytes) {
        final bytes? => SaveItem.bytes(
          bytes(index),
          name: 'contract-$index.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
        null => SaveItem.file(
          harness.file(index),
          name: 'contract-$index.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      };

      List<SaveItem> batch(int count) => [
        for (var i = 0; i < count; i++) photo(i),
      ];

      SaveJob save(List<SaveItem> items) =>
          harness.saver.save(items, harness.destination);

      test('one batch is one job, with a result per item in order', () async {
        final job = save(batch(3));
        final other = save(batch(1));
        final results = await job.results;
        await other.results;

        expect(job.id, isNot(other.id));
        expect(results, hasLength(3));
        expect(results, everyElement(isA<SaveResult$Saved>()));
        expect(diagnostics.whereOp(SaveOp.jobStarted).map((e) => e.jobId), [
          job.id,
          other.id,
        ]);
        expect(
          diagnostics
              .whereIds(jobId: job.id)
              .where((e) => e.op == SaveOp.jobFinished),
          hasLength(1),
        );
      });

      test('progress never goes back and ends at 1', () async {
        final job = save(batch(3));
        final seen = <double>[job.progress.value];
        job.progress.addListener(() => seen.add(job.progress.value));
        await job.results;

        for (var i = 1; i < seen.length; i++) {
          expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
        }
        expect(seen.first, greaterThanOrEqualTo(0));
        expect(job.progress.value, 1);
      });

      test('a cancel right after save cancels every item', () async {
        final job = save(batch(2))..cancel();
        expect(await job.results, [
          const SaveResult.cancelled(),
          const SaveResult.cancelled(),
        ]);
        expect(job.progress.value, 1);
      });

      test('a cancel mid-copy keeps the saved items and cancels the rest; '
          'in one block it has no effect', () async {
        final job = save(batch(3));
        job.progress.addListener(() {
          // Past the first item's share: the first is saved, the second
          // under way.
          if (job.progress.value > 0.34) job.cancel();
        });
        final results = await job.results;

        if (harness.changeBlock) {
          expect(results, everyElement(isA<SaveResult$Saved>()));
          return;
        }
        expect(results.first, isA<SaveResult$Saved>());
        expect(results.last, const SaveResult.cancelled());
        for (final result in results) {
          expect(
            result,
            anyOf(isA<SaveResult$Saved>(), isA<SaveResult$Cancelled>()),
          );
        }
      });

      test('a failed block fails every item', () async {
        final fail = harness.failBlock;
        if (!harness.changeBlock || fail == null) {
          markTestSkipped('no change block');
          return;
        }
        fail();
        final results = await save(batch(2)).results;
        expect(results, everyElement(isA<SaveResult$Failed>()));
        expect(results.toSet(), hasLength(1), reason: 'one failure for all');
      });

      test('denied access fails every item accessDenied', () async {
        final deny = harness.denyAccess;
        if (deny == null) {
          markTestSkipped('the platform asks for no access');
          return;
        }
        deny();
        final results = await save(batch(2)).results;
        expect(
          results,
          everyElement(const SaveResult.failed(SaveFailure.accessDenied)),
        );
      });

      test('a leased file is copied, never moved, and its lease '
          'released', () async {
        var released = 0;
        final path = harness.file(0);
        final item = SaveItem.leased(
          ContentFileLease(path: path, onRelease: () async => released++),
          name: 'contract-leased.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
          move: true,
        );
        final results = await save([item]).results;

        expect(results.single, isA<SaveResult$Saved>());
        expect(released, 1);
        expect(diagnostics.whereOp(SaveOp.moveRefused), hasLength(1));
      });

      test('a lease is released when its item is cancelled', () async {
        var released = 0;
        final item = SaveItem.leased(
          ContentFileLease(
            path: harness.file(0),
            onRelease: () async => released++,
          ),
          name: 'contract-leased.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        );
        final job = save([item])..cancel();
        expect(await job.results, [const SaveResult.cancelled()]);
        expect(released, 1);
      });

      test('a non-media file sent to the gallery fails '
          'unsupportedFormat', () async {
        if (harness.destination is! SaveDestination$Gallery) {
          markTestSkipped('the contract runs to another destination');
          return;
        }
        final results = await save([
          SaveItem.file(
            harness.file(0),
            name: 'contract.pdf',
            mimeType: 'application/pdf',
            kind: SaveItemKind.file,
          ),
        ]).results;
        expect(results, [
          const SaveResult.failed(SaveFailure.unsupportedFormat),
        ]);
      });

      test('every event is a save event of a job, with no user '
          'content', () async {
        await save(batch(2)).results;
        final events = diagnostics.whereCategory('save');
        expect(events, isNotEmpty);
        for (final event in events) {
          expect(event.jobId, isNotNull);
          for (final value in event.fields.values) {
            expect('$value', isNot(contains('contract')));
            expect('$value', isNot(contains('/')));
          }
        }
        expect(diagnostics.errors, isEmpty);
      });
    });
  }
}
