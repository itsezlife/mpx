import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/transfer/tracked_transfers.dart';

/// What a [TrackedTransfers] contract run needs besides the implementation.
///
/// The download clauses always run. The upload clauses run when the harness
/// can start an upload ([startUpload]), and the clauses of a job the system
/// or the network paused run when it can pause one ([interrupt]).
final class TrackedTransfersHarness {
  /// Creates a harness around [transfers].
  const TrackedTransfersHarness({
    required this.transfers,
    required this.content,
    required this.advance,
    this.interrupt,
    this.resumeInterrupted,
    this.uploadSource,
    this.startUpload,
    this.publish,
    this.dispose,
    this.maxSteps = 200,
  });

  /// The implementation under test.
  final TrackedTransfers transfers;

  /// A key whose content the implementation can download, in more than one
  /// step of bytes, and that is not local yet.
  final MediaKey content;

  /// Lets every job move one step further: a chunk of bytes, a state.
  final Future<void> Function() advance;

  /// Pauses [key]'s job as the system ending its envelope, or the network
  /// going away, would; null when the harness cannot.
  final Future<void> Function(MediaKey key)? interrupt;

  /// Undoes [interrupt]: the app is in the foreground, the network is back.
  final Future<void> Function(MediaKey key)? resumeInterrupted;

  /// A key that is the source of the upload [startUpload] starts.
  final MediaKey? uploadSource;

  /// Starts an upload of [uploadSource]'s content, in more than one step of
  /// bytes; null when the harness cannot.
  final Future<void> Function()? startUpload;

  /// Publishes the uploaded content under its server identity, after which
  /// the source reads none.
  final Future<void> Function()? publish;

  /// Releases what the harness made.
  final Future<void> Function()? dispose;

  /// How many [advance] steps a job may take before the run gives up.
  final int maxSteps;
}

/// The contract every [TrackedTransfers] meets: the mapping of its jobs onto
/// [AssetTransfer] in both directions, as surfaces see it at the seam.
abstract final class TrackedTransfersContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(FutureOr<TrackedTransfersHarness> Function() create) {
    group('TrackedTransfers contract', () {
      late TrackedTransfersHarness harness;
      late TrackedTransfers transfers;

      setUp(() async {
        harness = await create();
        transfers = harness.transfers;
      });
      tearDown(() async => harness.dispose?.call());

      // Every value [key]'s watchers hear from now on, starting with the
      // current one.
      List<AssetTransfer> record(MediaKey key) {
        final watched = transfers.watch(key);
        final seen = <AssetTransfer>[watched.value];
        void heard() {
          if (watched.value != seen.last) seen.add(watched.value);
        }

        watched.addListener(heard);
        addTearDown(() => watched.removeListener(heard));
        return seen;
      }

      Future<void> advanceUntil(bool Function() done) async {
        for (var step = 0; step < harness.maxSteps && !done(); step++) {
          await harness.advance();
        }
        expect(done(), isTrue, reason: 'the job did not get there in time');
      }

      AssetTransfer valueOf(MediaKey key) => transfers.watch(key).value;

      test('a key no job has reads none, and cancel changes nothing', () {
        expect(valueOf(harness.content), AssetTransfer.none);
        transfers.cancel(harness.content);
        expect(valueOf(harness.content), AssetTransfer.none);
      });

      test('a download walks waiting, receiving, none', () async {
        final seen = record(harness.content);

        transfers.download(harness.content);
        await advanceUntil(
          () =>
              seen.length > 1 && valueOf(harness.content) is AssetTransfer$None,
        );

        expect(seen.first, AssetTransfer.none);
        expect(seen[1], isA<AssetTransfer$Waiting>());
        expect(seen.last, AssetTransfer.none);
        final between = seen.sublist(2, seen.length - 1);
        expect(between, isNotEmpty, reason: 'no bytes were reported');
        expect(between, everyElement(isA<AssetTransfer$Receiving>()));
        final received = [
          for (final value in between)
            (value as AssetTransfer$Receiving).received,
        ];
        expect(received, orderedEquals([...received]..sort()));
      });

      test('a second download of the key joins the first', () async {
        transfers.download(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$Receiving,
        );
        final before = valueOf(harness.content) as AssetTransfer$Receiving;

        transfers.download(harness.content, origin: TransferOrigin.auto);

        final after = valueOf(harness.content);
        expect(after, isA<AssetTransfer$Receiving>());
        expect(
          (after as AssetTransfer$Receiving).received,
          greaterThanOrEqualTo(before.received),
        );
      });

      test('cancel of a download ends in awaitingUser with its bytes, and '
          'download resumes it to the end', () async {
        transfers.download(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$Receiving,
        );
        final received =
            (valueOf(harness.content) as AssetTransfer$Receiving).received;

        transfers.cancel(harness.content);
        await harness.advance();

        final cancelled = valueOf(harness.content);
        expect(cancelled, isA<AssetTransfer$AwaitingUser>());
        expect(
          (cancelled as AssetTransfer$AwaitingUser).received,
          greaterThanOrEqualTo(received),
        );

        transfers.download(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$None,
        );
      });

      test('leaseFile lends the whole content once it is local', () async {
        expect(await transfers.leaseFile(harness.content), isNull);

        transfers.download(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$None,
        );
        final lease = await transfers.leaseFile(harness.content);

        expect(lease, isNotNull);
        expect(lease!.path, isNotEmpty);
        await lease.release();
        await lease.release();
        expect(lease.isReleased, isTrue);
      });

      test('a download the system or the network paused holds its last '
          'receiving value, and goes on when it may', () async {
        final interrupt = harness.interrupt;
        if (interrupt == null) return;
        transfers.download(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$Receiving,
        );

        await interrupt(harness.content);
        final held = valueOf(harness.content);
        expect(held, isA<AssetTransfer$Receiving>());
        await harness.advance();
        await harness.advance();
        expect(valueOf(harness.content), held);

        await harness.resumeInterrupted?.call(harness.content);
        await advanceUntil(
          () => valueOf(harness.content) is AssetTransfer$None,
        );
      });

      test('an upload walks sending, sent, and none once published', () async {
        final start = harness.startUpload;
        final source = harness.uploadSource;
        if (start == null || source == null) return;
        final seen = record(source);

        await start();
        await advanceUntil(() => valueOf(source) == AssetTransfer.sent);

        final sending = seen
            .where((value) => value is! AssetTransfer$Waiting)
            .skipWhile((value) => value is AssetTransfer$None)
            .takeWhile((value) => value != AssetTransfer.sent)
            .toList();
        expect(sending, isNotEmpty, reason: 'no bytes were reported');
        expect(sending, everyElement(isA<AssetTransfer$Sending>()));

        await harness.publish?.call();
        await advanceUntil(() => valueOf(source) is AssetTransfer$None);
      });

      test('an upload the system or the network paused holds its last '
          'sending value', () async {
        final start = harness.startUpload;
        final source = harness.uploadSource;
        final interrupt = harness.interrupt;
        if (start == null || source == null || interrupt == null) return;

        await start();
        await advanceUntil(() => valueOf(source) is AssetTransfer$Sending);
        await interrupt(source);
        final held = valueOf(source);
        expect(held, isA<AssetTransfer$Sending>());
        await harness.advance();
        await harness.advance();

        expect(valueOf(source), held);
      });
    });
  }
}
