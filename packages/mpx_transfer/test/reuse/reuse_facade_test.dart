import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_reuse_facade_');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<Transfers> open({ReusePolicy reuse = const ReusePolicy()}) =>
      Transfers.open(
        cacheKeyOf: (key) => key.encoded,
        lifecycle: ManualPlaybackLifecycleSource(),
        directory: directory.path,
        reuse: reuse,
      );

  final key = ReuseKey.host(
    'asset-7@2026-11-02',
    preparation: const PreparationIntent.video(),
  );
  final transport = FakeUploadTransport();
  final file = RemoteRef('remote-7');

  test('the default expiry is 7 days', () {
    expect(ReusePolicy.defaultExpiry, const Duration(days: 7));
    expect(const ReusePolicy().expiry, const Duration(days: 7));
    expect(const ReusePolicy().enabled, isTrue);
    expect(const ReusePolicy.off().enabled, isFalse);
  });

  test('Transfers.open keeps the table beside the journal, on by default '
      'with the default expiry', () async {
    final transfers = await open();
    expect(transfers.reuse.policy, const ReusePolicy());
    transfers.reuse.store(key, transport, file: file);
    await transfers.dispose();
    expect(
      File('${directory.path}/mpx_transfer/reuse.snapshot').existsSync(),
      isTrue,
    );
    expect(
      File('${directory.path}/mpx_transfer/journal.snapshot').existsSync(),
      isTrue,
    );
  });

  test('a stored source survives a kill', () async {
    final transfers = await open();
    transfers.reuse.store(key, transport, file: file);
    await transfers.reuse.idle;
    transfers.debugKill();

    final next = await open();
    addTearDown(next.dispose);
    expect((await next.reuse.lookup(key, transport))?.file, file);
  });

  test('the host turns the table off', () async {
    final transfers = await open(reuse: const ReusePolicy.off());
    addTearDown(transfers.dispose);
    transfers.reuse.store(key, transport, file: file);
    expect(await transfers.reuse.lookup(key, transport), isNull);
    expect(transfers.debugSnapshot().reuse?.enabled, isFalse);
  });

  test(
    'debugSnapshot has the reuse section: entries, hits and misses',
    () async {
      RecordingDiagnostics.install();
      final h = await harness();
      final reuse = h.transfers.reuse;
      reuse.store(key, transport, file: file);
      await reuse.lookup(key, transport);
      await reuse.lookup(key, transport);
      await reuse.lookup(ReuseKey.host('other'), transport);
      final snapshot = h.transfers.debugSnapshot().reuse!;
      expect(snapshot.enabled, isTrue);
      expect(snapshot.entries, 1);
      expect(snapshot.hits, 2);
      expect(snapshot.misses, 1);
    },
  );

  test('lookup events carry the correlation ids the caller gives', () async {
    final recorder = RecordingDiagnostics.install();
    final h = await harness();
    const media = photo;
    h.transfers.reuse.store(key, transport, file: file);
    await h.transfers.reuse.lookup(
      key,
      transport,
      jobId: 'job-1',
      itemId: 'item-1',
      mediaKey: media,
    );
    for (final op in [ReuseOp.hit, ReuseOp.lookup]) {
      final event = recorder.whereOp(op).single;
      expect(event.jobId, 'job-1');
      expect(event.itemId, 'item-1');
      expect(event.mediaKey, media);
    }
  });

  test('a store that refuses a write is reported with no path', () async {
    final recorder = RecordingDiagnostics.install();
    final table = await ReuseTable.open(_RefusingStore());
    table.store(key, transport, file: file);
    await table.idle;
    final failed = recorder.whereOp(JournalOp.writeFailed);
    expect(failed, isNotEmpty);
    expect(failed.first.fields, {'code': 'refused', 'table': 'reuse'});
    expect(await table.lookup(key, transport), isNotNull);
  });
}

/// Reads back nothing and refuses every write.
final class _RefusingStore implements JournalStore {
  @override
  JournalStoreKind get kind => JournalStoreKind.file;

  @override
  Future<Uint8List> read(JournalBlob blob) async => Uint8List(0);

  @override
  Future<void> append(Uint8List bytes) async =>
      throw const FileSystemException('refused', '/secret');

  @override
  Future<void> replace({
    required Uint8List snapshot,
    required Uint8List log,
  }) async => throw const FileSystemException('refused', '/secret');

  @override
  Future<void> close() async {}

  @override
  String errorCode(Object error) => 'refused';
}
