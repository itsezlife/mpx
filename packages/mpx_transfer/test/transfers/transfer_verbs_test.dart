import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

TransferId _queued(TransfersHarness h) => h.addUpload(total: 100);

TransferId _running(TransfersHarness h) {
  final id = h.addUpload(total: 100);
  h.runner.progress(id, 40, total: 100);
  return id;
}

TransferId _pausedByUser(TransfersHarness h) {
  final id = _running(h);
  h.transfers.pause(id);
  return id;
}

TransferId _pausedForNetwork(TransfersHarness h) {
  final id = _running(h);
  h.transfers.connectivityChanged(online: false);
  h.runner.fail(id, TransferFailureKind.network);
  return id;
}

TransferId _failed(TransfersHarness h) {
  final id = _running(h);
  h.runner.fail(id, TransferFailureKind.server, retryable: false);
  return id;
}

TransferId _completed(TransfersHarness h) {
  final id = _running(h);
  h.runner.complete(id, const FakeTransferResult('ref'));
  return id;
}

/// Moves a fresh upload to each state a verb may meet.
const Map<String, TransferId Function(TransfersHarness h)> _states = {
  'queued': _queued,
  'running': _running,
  'paused(user)': _pausedByUser,
  'paused(awaitingNetwork)': _pausedForNetwork,
  'failed': _failed,
  'completed': _completed,
};

void main() {
  group('state model', () {
    test('a new job is queued with its total', () async {
      final h = await harness();
      final id = h.addUpload(total: 100);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.queued(total: 100),
      );
      expect(h.runner.isRunning(id), isTrue);
    });

    test('the first progress runs it, later ones move it on', () async {
      final h = await harness();
      final id = h.addUpload();
      h.runner.progress(id, 10, total: 100, estimated: true);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.running(done: 10, total: 100, estimated: true),
      );
      h.runner.progress(id, 60, total: 100);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.running(done: 60, total: 100),
      );
    });

    test('a completion holds the result', () async {
      final h = await harness();
      final id = _completed(h);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.completed(FakeTransferResult('ref')),
      );
    });

    test('a failure keeps the bytes moved and whether to retry', () async {
      final h = await harness();
      final id = _running(h);
      h.runner.fail(id, TransferFailureKind.sourceLost, retryable: false);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.failed(
          kind: TransferFailureKind.sourceLost,
          retryable: false,
          done: 40,
          total: 100,
        ),
      );
    });

    test('a network failure while online fails the job', () async {
      final h = await harness();
      final id = _running(h);
      h.runner.fail(id, TransferFailureKind.network);
      expect(
        await stateOf(h.transfers, id),
        isA<TransferState$Failed>()
            .having((s) => s.kind, 'kind', TransferFailureKind.network)
            .having((s) => s.retryable, 'retryable', isTrue),
      );
    });
  });

  group('pause', () {
    for (final MapEntry(key: name, value: setup) in _states.entries) {
      final applies = switch (name) {
        'queued' || 'running' || 'paused(awaitingNetwork)' => true,
        _ => false,
      };
      test('${applies ? 'pauses' : 'leaves'} a $name job', () async {
        final h = await harness();
        final id = setup(h);
        final before = await stateOf(h.transfers, id);

        expect(h.transfers.pause(id), applies);

        final after = await stateOf(h.transfers, id);
        if (applies) {
          expect(
            after,
            TransferState.paused(
              reason: PauseReason.user,
              done: before!.done,
              total: before.total,
            ),
          );
          expect(h.runner.isRunning(id), isFalse);
        } else {
          expect(after, before);
        }
      });
    }

    test('stops the run, and a late report changes nothing', () async {
      final h = await harness();
      final id = _running(h);
      h.transfers.pause(id);
      expect(h.runner.stops, [id]);
      expect(() => h.runner.progress(id, 90), throwsStateError);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(
          reason: PauseReason.user,
          done: 40,
          total: 100,
        ),
      );
    });
  });

  group('resume', () {
    for (final MapEntry(key: name, value: setup) in _states.entries) {
      final applies = name.startsWith('paused');
      test('${applies ? 'queues' : 'leaves'} a $name job', () async {
        final h = await harness();
        final id = setup(h);
        final before = await stateOf(h.transfers, id);
        final starts = h.runner.starts.length;

        expect(h.transfers.resume(id), applies);

        final after = await stateOf(h.transfers, id);
        if (applies) {
          expect(after, TransferState.queued(total: before!.total));
          expect(h.runner.isRunning(id), isTrue);
          expect(h.runner.starts, hasLength(starts + 1));
        } else {
          expect(after, before);
          expect(h.runner.starts, hasLength(starts));
        }
      });
    }
  });

  group('retry', () {
    for (final MapEntry(key: name, value: setup) in _states.entries) {
      final applies = name == 'failed';
      test('${applies ? 'queues' : 'leaves'} a $name job', () async {
        final h = await harness();
        final id = setup(h);
        final before = await stateOf(h.transfers, id);

        expect(h.transfers.retry(id), applies);

        final after = await stateOf(h.transfers, id);
        if (applies) {
          expect(after, TransferState.queued(total: before!.total));
          expect(h.runner.isRunning(id), isTrue);
        } else {
          expect(after, before);
        }
      });
    }
  });

  group('cancel', () {
    for (final MapEntry(key: name, value: setup) in _states.entries) {
      test('removes a $name job', () async {
        final h = await harness();
        final id = setup(h);

        expect(h.transfers.cancel(id), isTrue);

        expect(await stateOf(h.transfers, id), isNull);
        expect(h.runner.isRunning(id), isFalse);
        expect(h.transfers.cancel(id), isFalse);
      });
    }

    test('stops a running job', () async {
      final h = await harness();
      final id = _running(h);
      h.transfers.cancel(id);
      expect(h.runner.stops, [id]);
    });

    test('lets a cancelled download key make a new job', () async {
      final h = await harness();
      final id = h.addDownload(photo);
      h.transfers.cancel(id);
      expect(h.addDownload(photo), id);
      expect(await stateOf(h.transfers, id), const TransferState.queued());
    });
  });

  group('setPriority', () {
    for (final MapEntry(key: name, value: setup) in _states.entries) {
      final applies = name != 'completed';
      test('${applies ? 'moves' : 'leaves'} a $name job', () async {
        final h = await harness();
        final id = setup(h);

        expect(
          h.transfers.setPriority(id, RequestPriority.background),
          applies,
        );

        final job = (await jobsOf(h.transfers)).single;
        if (applies) {
          expect(job.priority, RequestPriority.background);
          expect(h.runner.priorities, [(id, RequestPriority.background)]);
        } else {
          expect(job.priority, RequestPriority.visible);
          expect(h.runner.priorities, isEmpty);
        }
      });
    }

    test('changes nothing at the priority the job has', () async {
      final h = await harness();
      final id = h.addUpload();
      expect(h.transfers.setPriority(id, RequestPriority.visible), isFalse);
    });
  });

  test('every verb answers false for an unknown id', () async {
    final h = await harness();
    final id = TransferId.issue();
    expect(h.transfers.pause(id), isFalse);
    expect(h.transfers.resume(id), isFalse);
    expect(h.transfers.retry(id), isFalse);
    expect(h.transfers.cancel(id), isFalse);
    expect(h.transfers.setPriority(id, RequestPriority.preload), isFalse);
  });
}
