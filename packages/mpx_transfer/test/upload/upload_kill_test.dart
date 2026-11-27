import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

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
}
