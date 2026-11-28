import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/src/diagnostics/reuse_op.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/testing/fake_upload_transport.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// The contract the reuse table meets over every [JournalStore]: a stored
/// source hits and a new one misses, the host's expiry and the transport's
/// `reuse` judgement (a lifetime, or a validity call) drop what is no
/// longer good, a dropped entry misses, the host's switch turns the table
/// off, and what was written reads back at the next start.
abstract final class ReuseTableContract {
  /// Runs it as a test group named after [name].
  ///
  /// [storage] is called once per test, inside its `setUp`, for fresh,
  /// empty storage; it answers how to open a store over that storage, and
  /// each call of the answer is a new start over the same bytes; storage
  /// that takes time to make answers a future of it. Clean the storage up
  /// with `addTearDown` inside [storage].
  static void run(
    String name,
    FutureOr<JournalStore Function()> Function() storage,
  ) {
    group('ReuseTable contract ($name)', () {
      late JournalStore Function() openStore;
      late RecordingDiagnostics recorder;
      late DateTime time;

      setUp(() async {
        openStore = await storage();
        recorder = RecordingDiagnostics.install();
        time = DateTime.utc(2026, 11, 27, 12);
      });
      Future<ReuseTable> start({
        ReusePolicy policy = const ReusePolicy(),
      }) async {
        final table = await ReuseTable.open(
          openStore(),
          policy: policy,
          now: () => time,
        );
        // Closed before the storage is cleaned up, which was registered
        // first: a write still under way finishes before its files go.
        addTearDown(table.close);
        return table;
      }

      /// Closes [table] and opens the next start over what it wrote.
      Future<ReuseTable> restart(
        ReuseTable table, {
        ReusePolicy policy = const ReusePolicy(),
      }) async {
        await table.close();
        return start(policy: policy);
      }

      List<Map<String, Object>> fieldsOf(ReuseOp op) => [
        for (final event in recorder.whereOp(op)) event.fields,
      ];

      test('a source never stored misses', () async {
        final table = await start();
        expect(await table.lookup(_photo, _lifetimeTransport), isNull);
        expect(fieldsOf(ReuseOp.lookup), [
          {'result': 'miss'},
        ]);
        expect(table.debugSnapshot().misses, 1);
      });

      test('a stored source hits with its references, after a restart '
          'too', () async {
        var table = await start();
        table.store(
          _photo,
          _lifetimeTransport,
          file: _file,
          thumbnail: _thumbnail,
        );
        time = time.add(const Duration(minutes: 10));
        final hit = await table.lookup(_photo, _lifetimeTransport);
        expect(hit?.file, _file);
        expect(hit?.thumbnail, _thumbnail);
        expect(fieldsOf(ReuseOp.stored), [
          {'expiresInH': ReusePolicy.defaultExpiry.inHours},
        ]);
        expect(fieldsOf(ReuseOp.hit), [
          {'ageS': 600, 'judgedBy': 'lifetime'},
        ]);

        table = await restart(table);
        final again = await table.lookup(_photo, _lifetimeTransport);
        expect(again?.file, _file);
        expect(again?.thumbnail, _thumbnail);
        expect(again?.storedAt, DateTime.utc(2026, 11, 27, 12));
        expect(table.debugSnapshot().entries, 1);
      });

      test('another preparation, another fingerprint or another transport '
          'misses', () async {
        final table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        expect(await table.lookup(_photoHigh, _lifetimeTransport), isNull);
        expect(await table.lookup(_otherFile, _lifetimeTransport), isNull);
        expect(await table.lookup(_photo, _otherTransport), isNull);
        expect(await table.lookup(_photo, _lifetimeTransport), isNotNull);
      });

      test('an entry past the host expiry is dropped as expired', () async {
        final table =
            await start(policy: const ReusePolicy(expiry: Duration(hours: 2)))
              ..store(_photo, _validityTransport(valid: true), file: _file);
        time = time.add(const Duration(hours: 2));
        expect(
          await table.lookup(_photo, _validityTransport(valid: true)),
          isNull,
        );
        expect(fieldsOf(ReuseOp.invalidated), [
          {'why': 'expired'},
        ]);
        expect(table.debugSnapshot().entries, 0);
      });

      test('an entry past the host expiry is gone at the next start', () async {
        var table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        time = time.add(ReusePolicy.defaultExpiry);
        table = await restart(table);
        expect(table.debugSnapshot().entries, 0);
        expect(fieldsOf(ReuseOp.invalidated), [
          {'why': 'expired'},
        ]);
      });

      test("past the transport's lifetime a reference is judged invalid and "
          'dropped', () async {
        final table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        time = time.add(const Duration(hours: 23, minutes: 59));
        expect(await table.lookup(_photo, _lifetimeTransport), isNotNull);
        time = time.add(const Duration(minutes: 1));
        expect(await table.lookup(_photo, _lifetimeTransport), isNull);
        expect(fieldsOf(ReuseOp.judgedInvalid), [
          {'judgedBy': 'lifetime'},
        ]);
        expect(table.debugSnapshot().entries, 0);
      });

      test(
        "the transport's validity call judges every stored reference",
        () async {
          final asked = <RemoteRef>[];
          final transport = _validityTransport(valid: true, asked: asked);
          final table = await start()
            ..store(_photo, transport, file: _file, thumbnail: _thumbnail);
          expect((await table.lookup(_photo, transport))?.file, _file);
          expect(asked, [_file, _thumbnail]);
          expect(fieldsOf(ReuseOp.hit).single['judgedBy'], 'validityCall');
        },
      );

      test('a reference the validity call refuses is dropped', () async {
        final table = await start()
          ..store(_photo, _validityTransport(valid: false), file: _file);
        expect(
          await table.lookup(_photo, _validityTransport(valid: false)),
          isNull,
        );
        expect(fieldsOf(ReuseOp.judgedInvalid), [
          {'judgedBy': 'validityCall'},
        ]);
        expect(table.debugSnapshot().entries, 0);
      });

      test('a validity call that throws misses and keeps the entry', () async {
        final failing = FakeUploadTransport(
          id: 'validity',
          capabilities: _capabilities(
            UploadReuse.validity((_) async => throw StateError('offline')),
          ),
        );
        final table = await start()
          ..store(_photo, failing, file: _file);
        expect(await table.lookup(_photo, failing), isNull);
        expect(fieldsOf(ReuseOp.judgedInvalid), [
          {'judgedBy': 'validityCall', 'callFailed': true},
        ]);
        expect(
          await table.lookup(_photo, _validityTransport(valid: true)),
          isNotNull,
        );
      });

      test('a dropped entry misses, after a restart too', () async {
        var table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        expect(
          table.invalidate(_photo, _lifetimeTransport, itemId: 'item-1'),
          isTrue,
        );
        expect(table.invalidate(_photo, _lifetimeTransport), isFalse);
        expect(await table.lookup(_photo, _lifetimeTransport), isNull);
        final invalidated = recorder.whereOp(ReuseOp.invalidated).single;
        expect(invalidated.fields, {'why': 'reuploadItems'});
        expect(invalidated.itemId, 'item-1');

        table = await restart(table);
        expect(await table.lookup(_photo, _lifetimeTransport), isNull);
      });

      test('a new upload of the same source replaces its entry', () async {
        var table = await start()
          ..store(_photo, _lifetimeTransport, file: _file)
          ..store(_photo, _lifetimeTransport, file: _thumbnail);
        table = await restart(table);
        expect(
          (await table.lookup(_photo, _lifetimeTransport))?.file,
          _thumbnail,
        );
        expect(table.debugSnapshot().entries, 1);
      });

      test('the host switch off looks nothing up and stores nothing, and '
          'leaves what was stored', () async {
        var table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        table = await restart(table, policy: const ReusePolicy.off());
        expect(await table.lookup(_photo, _lifetimeTransport), isNull);
        table.store(_otherFile, _lifetimeTransport, file: _file);
        expect(fieldsOf(ReuseOp.lookup), [
          {'result': 'disabled'},
        ]);
        expect(recorder.whereOp(ReuseOp.stored), hasLength(1));
        expect(table.debugSnapshot().enabled, isFalse);
        expect(table.debugSnapshot().misses, 0);

        table = await restart(table);
        expect(await table.lookup(_photo, _lifetimeTransport), isNotNull);
        expect(await table.lookup(_otherFile, _lifetimeTransport), isNull);
      });

      test('a kill keeps every entry written before it', () async {
        final table = await start()
          ..store(_photo, _lifetimeTransport, file: _file)
          ..store(_otherFile, _lifetimeTransport, file: _thumbnail)
          ..invalidate(_otherFile, _lifetimeTransport);
        await table.idle;
        table.abandon();
        final next = await start();
        expect((await next.lookup(_photo, _lifetimeTransport))?.file, _file);
        expect(await next.lookup(_otherFile, _lifetimeTransport), isNull);
      });

      test('no event carries a fingerprint, a path or a reference', () async {
        final table = await start()
          ..store(_photo, _lifetimeTransport, file: _file);
        await table.lookup(_photo, _lifetimeTransport);
        table.invalidate(_photo, _lifetimeTransport);
        final text = recorder.events.map((e) => '${e.fields}').join();
        for (final secret in ['asset-42', '/media', _file.id, 'thumb']) {
          expect(text, isNot(contains(secret)));
        }
      });
    });
  }
}

final ReuseKey _photo = ReuseKey.host(
  'asset-42@2026-11-01',
  preparation: const PreparationIntent.photo(),
);
final ReuseKey _photoHigh = ReuseKey.host(
  'asset-42@2026-11-01',
  preparation: const PreparationIntent.photo(highQuality: true),
);
final ReuseKey _otherFile = ReuseKey.file(
  path: '/media/clip.mp4',
  size: 1000,
  modified: DateTime.utc(2026, 11),
);

final RemoteRef _file = RemoteRef(
  'remote-file-1',
  attributes: const {'a': 'b'},
);
final RemoteRef _thumbnail = RemoteRef('remote-thumb-1');

final FakeUploadTransport _lifetimeTransport = FakeUploadTransport();
final FakeUploadTransport _otherTransport = FakeUploadTransport(id: 'other');

/// A transport named `validity` whose call answers [valid], adding each
/// reference it was asked about to [asked].
FakeUploadTransport _validityTransport({
  required bool valid,
  List<RemoteRef>? asked,
}) => FakeUploadTransport(
  id: 'validity',
  capabilities: _capabilities(
    UploadReuse.validity((ref) async {
      asked?.add(ref);
      return valid;
    }),
  ),
);

UploadCapabilities _capabilities(UploadReuse reuse) => UploadCapabilities(
  partSize: FakeUploadTransport.defaultCapabilities.partSize,
  reuse: reuse,
);
