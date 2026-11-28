import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/testing.dart'
    show FakeUploadTransport, UploadsHarness;

import 'upload_support.dart';

/// Longer than the test's progress window, so the window before it has
/// been written.
const Duration _pastWindow = Duration(milliseconds: 80);

void main() {
  test('a kill mid-upload, then a restart, resends no journaled part and '
      'loses at most one progress window', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      holdParts: true,
    );
    final h = await uploads([
      transport,
    ], progressInterval: const Duration(milliseconds: 20));
    final id = h.upload(sourceOf(50));
    await pumpEventQueue();
    for (final index in [0, 1]) {
      transport.ack(index);
      await pumpEventQueue();
    }
    await Future<void>.delayed(_pastWindow);
    await h.settle();

    // Part 2 is acknowledged inside a window the kill cuts short.
    transport.ack(2);
    await pumpEventQueue();
    final sentBefore = transport.sent.length;
    transport.holdParts = false;
    await h.kill();

    expect(h.uploadOf(id)!.parts.keys, unorderedEquals([0, 1]));
    expect(h.uploadOf(id)!.highWaterMark, 20);
    await pumpEventQueue();
    final resent = transport.sent.skip(sentBefore).map((part) => part.index);
    expect(resent, [2, 3, 4]);
    expect(transport.opens.last.resumeToken, 'fake-token-1');
    expect(
      await stateOf(h.transfers, id),
      TransferState.completed(RemoteRef('fake-1')),
    );
    expect(transport.finishes.single.parts, hasLength(5));
  });

  test('a restart reopens with the token and keeps the receipts for '
      'finish', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 30,
      holdParts: true,
    );
    final h = await uploads([transport]);
    final id = h.upload(sourceOf(30));
    await pumpEventQueue();
    transport.ack(1, receipt: 'kept');
    await pumpEventQueue();
    transport.holdParts = false;
    await h.restart();
    await pumpEventQueue();
    expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    expect(transport.finishes.single.parts, const [
      UploadPartAck(receipt: 'receipt-0'),
      UploadPartAck(receipt: 'kept'),
      UploadPartAck(receipt: 'receipt-2'),
    ]);
    expect(
      transport.sent.where((part) => part.index == 1),
      hasLength(1),
      reason: 'the acknowledged part is not sent again',
    );
  });

  test('a session that does not continue starts the upload from zero, '
      'counted', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      holdParts: true,
    );
    final h = await uploads([transport]);
    final id = h.upload(sourceOf(20));
    await pumpEventQueue();
    transport.ack(0);
    await pumpEventQueue();
    transport
      ..acceptsResume = false
      ..holdParts = false;
    await h.restart();
    await pumpEventQueue();
    expect(transport.sent.map((part) => part.index), [0, 1, 0, 1]);
    expect(h.transfers.debugSnapshot().uploads!.restartsFromZero, 1);
    expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
  });

  test('an upload started again from zero never shows fewer bytes done '
      'than it showed', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      holdParts: true,
    );
    final h = await uploads([
      transport,
    ], progressInterval: const Duration(milliseconds: 20));
    final id = h.upload(sourceOf(30));
    await pumpEventQueue();
    transport
      ..ack(0)
      ..acceptsResume = false;
    await pumpEventQueue();
    transport.ack(1);
    await pumpEventQueue();
    await Future<void>.delayed(_pastWindow);
    await h.restart();
    final done = <int>[];
    final watching = h.transfers.watch().listen((jobs) {
      for (final job in jobs) {
        if (job.id == id && job.state is TransferState$Running) {
          done.add(job.state.done);
        }
      }
    });
    addTearDown(watching.cancel);
    await pumpEventQueue();
    transport.holdParts = false;
    for (final index in [0, 1, 2]) {
      if (transport.held.contains(index)) transport.ack(index);
      await pumpEventQueue();
    }
    await pumpEventQueue();
    expect(transport.sent.map((part) => part.index), [0, 1, 2, 0, 1, 2]);
    expect(done.first, 20, reason: 'the restart shows what was shown');
    expect(done, orderedEquals([...done]..sort()));
    expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
  });

  test('a transport that cannot resume opens without a token and starts '
      'from zero', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      resume: const UploadResume.none(),
      holdParts: true,
    );
    final h = await uploads([transport]);
    h.upload(sourceOf(20));
    await pumpEventQueue();
    transport.ack(0);
    await pumpEventQueue();
    transport.holdParts = false;
    await h.restart();
    await pumpEventQueue();

    expect(transport.opens.map((open) => open.resumeToken), [null, null]);
    expect(transport.sent.map((part) => part.index), [0, 1, 0, 1]);
  });

  group('a kill at each state boundary', () {
    late _HoldingStore store;
    late FakeUploadTransport transport;
    late UploadsHarness h;

    setUp(() async {
      store = _HoldingStore();
      transport = fakeTransport(partSize: 10, bytesInFlight: 30)
        ..closesOnFinish = true;
      h = await uploads(
        [transport],
        store: () => store,
        progressInterval: const Duration(milliseconds: 20),
      );
    });

    test('while queued: the restart sends every part once', () async {
      transport.holdParts = true;
      final id = h.upload(sourceOf(30));
      await h.settle();
      transport.holdParts = false;
      await h.kill();
      await pumpEventQueue();
      expect(
        await stateOf(h.transfers, id),
        TransferState.completed(RemoteRef('fake-1')),
      );
      expect(transport.finishes, hasLength(1));
    });

    test('with every part acknowledged and the finish not answered: the '
        'restart finishes once', () async {
      transport.holdFinishes = true;
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      expect(transport.heldFinishes, 1);
      await Future<void>.delayed(_pastWindow);
      await h.settle();
      final sent = transport.sent.length;
      transport.holdFinishes = false;
      await h.kill();
      await pumpEventQueue();
      expect(transport.sent, hasLength(sent), reason: 'no part sent again');
      expect(transport.finishes, hasLength(2));
      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    });

    test('after the finish answered and its answer was journaled, before '
        'the completed write: the restart completes with that answer and '
        'never finishes again', () async {
      store.holds = (text) => text.contains('"completed"');
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      expect(transport.finishes, hasLength(1));
      await h.kill();
      store.holds = null;
      await pumpEventQueue();

      expect(transport.finishes, hasLength(1));
      expect(transport.sent, hasLength(3));
      expect(
        await stateOf(h.transfers, id),
        TransferState.completed(RemoteRef('fake-1')),
      );
    });

    test('after the finish answered and before any of it was journaled: a '
        'refused second finish resends the upload from zero, not a '
        'failure', () async {
      store.holds = (text) =>
          text.contains('"finished"') || text.contains('"completed"');
      transport.holdFinishes = true;
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      await Future<void>.delayed(_pastWindow);
      await h.settle();
      transport
        ..holdFinishes = false
        ..answerFinish();
      await pumpEventQueue();
      expect(transport.finishes, hasLength(1));
      await h.kill();
      store.holds = null;
      await pumpEventQueue();

      final state = await stateOf(h.transfers, id);
      expect(state, isA<TransferState$Completed>());
      expect(transport.finishes, hasLength(3));
      expect(transport.opens.last.resumeToken, isNull);
      expect(transport.sent.map((part) => part.index), [0, 1, 2, 0, 1, 2]);
      expect(h.transfers.debugSnapshot().uploads!.restartsFromZero, 1);
    });

    test('a second refused finish of the resend fails the job', () async {
      store.holds = (text) =>
          text.contains('"finished"') || text.contains('"completed"');
      transport.holdFinishes = true;
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      await Future<void>.delayed(_pastWindow);
      await h.settle();
      transport
        ..holdFinishes = false
        ..answerFinish();
      await pumpEventQueue();
      await h.kill();
      store.holds = null;
      transport.failFinish(
        times: 2,
        error: const UploadTransportException('refused', status: 400),
      );
      await pumpEventQueue();
      expect(
        await stateOf(h.transfers, id),
        isA<TransferState$Failed>().having(
          (state) => state.retryable,
          'retryable',
          isFalse,
        ),
      );
    });

    test('after the completed write: the restart sends nothing', () async {
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      await h.settle();
      await h.kill();
      await pumpEventQueue();
      expect(transport.opens, hasLength(1));
      expect(transport.finishes, hasLength(1));
      expect(
        await stateOf(h.transfers, id),
        TransferState.completed(RemoteRef('fake-1')),
      );
    });
  });
}

/// A journal store in memory whose appends that [holds] matches never
/// land: they wait as a write a kill cuts short, and every write after
/// them waits behind.
final class _HoldingStore implements JournalStore {
  final MemoryJournalStore _memory = MemoryJournalStore();

  /// Holds an append whose frames' text it matches; null holds none.
  bool Function(String text)? holds;

  @override
  JournalStoreKind get kind => JournalStoreKind.memory;

  @override
  Future<Uint8List> read(JournalBlob blob) => _memory.read(blob);

  @override
  Future<void> append(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (holds?.call(text) ?? false) return Completer<void>().future;
    return _memory.append(bytes);
  }

  @override
  Future<void> replace({required Uint8List snapshot, required Uint8List log}) =>
      _memory.replace(snapshot: snapshot, log: log);

  @override
  Future<void> close() async {}

  @override
  String errorCode(Object error) => 'held';
}
