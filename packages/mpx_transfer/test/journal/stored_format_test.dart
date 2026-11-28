import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/publish/publish_journal.dart';
import 'package:mpx_transfer/src/publish/publish_record.dart';
import 'package:mpx_transfer/testing.dart' show FakeUploadTransport;

import 'stored_format_fixtures.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 27, 10);

Future<MemoryJournalStore> _storeOf(StoredBlobs blobs) async {
  final store = MemoryJournalStore();
  await store.replace(snapshot: blobs.snapshot, log: blobs.log);
  return store;
}

/// Every frame payload of [blobs], as JSON text, snapshot first.
List<String> _payloads(StoredBlobs blobs) => [
  for (final payload in [
    ...JournalFrames.decode(blobs.snapshot).payloads,
    ...JournalFrames.decode(blobs.log).payloads,
  ])
    jsonEncode(payload),
];

void main() {
  group('the transfer journal', () {
    for (final (name, fixture) in [
      ('as written', transferFixture),
      ('as folded', transferCompactedFixture),
    ]) {
      test('reads back the jobs $name', () async {
        final journal = await TransferJournal.open(
          await _storeOf(fixture),
          retention: const Duration(hours: 24),
          now: () => _t0,
          resultCodecs: Transfers.resultCodecs,
        );
        addTearDown(journal.close);
        final u1 = journal.record(const TransferId.parse('u-1'))!;
        expect(
          u1.job.state,
          const TransferState.failed(
            kind: TransferFailureKind.server,
            retryable: true,
            done: 16,
            total: 42,
          ),
        );
        expect(u1.job.tag, 'chat:1');
        expect(u1.envelopeHandle, 'h-1');
        expect(u1.upload!.parts, const {0: 'e0', 1: null});
        expect(u1.upload!.highWaterMark, 16);
        expect(u1.upload!.resumeToken, 'tok');
        expect(u1.upload!.owner!.itemId, 'a');
        expect(
          journal.job(const TransferId.parse('u-2'))!.state,
          TransferState.completed(
            RemoteRef('r-2', attributes: const {'etag': 'x'}),
          ),
        );
        final download = journal.job(TransferId.forDownload('ck-1'))!;
        expect(
          download.state,
          const TransferState.completed(DownloadedContent(bytes: 99)),
        );
        expect(download.key, const MediaKey.remote('photo-1'));
        expect(journal.job(const TransferId.parse('u-3')), isNull);
      });

      test('writes every record it holds $name to the same bytes', () {
        final codec = JournalCodec(Transfers.resultCodecs);
        for (final payload in _payloads(fixture)) {
          final json = jsonDecode(payload);
          if (json case {'header': _}) continue;
          expect(jsonEncode(codec.encode(codec.decode(json))), payload);
        }
      });
    }
  });

  group('the publish journal', () {
    for (final (name, fixture) in [
      ('as written', publishFixture),
      ('as folded', publishCompactedFixture),
    ]) {
      test('reads back the jobs $name', () async {
        final journal = await PublishJournal.open(
          await _storeOf(fixture),
          retention: const Duration(hours: 24),
          now: () => _t0,
        );
        addTearDown(journal.close);
        final record = journal.records.single;
        expect(record.id.value, 'p-01');
        expect(record.attempts, 3);
        expect(record.end, const PublishJobState.completed(null));
        expect(record.aliases, {'a': const MediaKey.remote('srv-a')});
        expect(record.items.map((item) => item.item.itemId), ['a', 'd']);
      });

      test('writes every record it holds $name to the same bytes', () {
        const codec = PublishRecordCodec();
        for (final payload in _payloads(fixture)) {
          final json = jsonDecode(payload) as Map<String, Object?>;
          if (json case {'put': final Map<String, Object?> put}) {
            expect(
              jsonEncode({'put': codec.encode(codec.decode(put))}),
              payload,
            );
          }
        }
      });
    }
  });

  group('the reuse table', () {
    for (final (name, fixture) in [
      ('as written', reuseFixture),
      ('as folded', reuseCompactedFixture),
    ]) {
      test('reads back the entries $name', () async {
        final table = await ReuseTable.open(
          await _storeOf(fixture),
          now: () => _t0,
        );
        addTearDown(table.close);
        final transport = FakeUploadTransport(id: 'tus');
        final first = await table.lookup(ReuseKey.host('asset-1'), transport);
        expect(first!.file, RemoteRef('f-1', attributes: const {'etag': 'y'}));
        expect(first.thumbnail, RemoteRef('t-1'));
        expect(first.storedAt, _t0);
        final second = await table.lookup(
          ReuseKey.host(
            'asset-2',
            preparation: const PreparationIntent.photo(),
          ),
          transport,
        );
        expect(second!.file, RemoteRef('f-2'));
        expect(second.thumbnail, isNull);
        expect(await table.lookup(ReuseKey.host('asset-3'), transport), isNull);
        expect(table.debugSnapshot().entries, 2);
      });
    }
  });
}
