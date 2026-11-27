import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  late RecordingDiagnostics recorder;

  setUp(() => recorder = RecordingDiagnostics.install());

  const server = MediaKey.remote('server-a');

  group('published', () {
    test('completes the job, then aliases each server key to its item local '
        'key through the cache key mapping', () async {
      final publisher = FakePublisher()
        ..answerWith(
          PublishOutcome.published(
            result: Uint8List.fromList([7]),
            serverKeys: const {'a': server},
          ),
        );
      late UploadsHarness h;
      final cache = _AliasRecorder(
        onAlias: () => (
          publishCalls: publisher.calls.length,
          state: h.transfers.debugSnapshot().publish!.jobs.isEmpty
              ? 'completed'
              : 'running',
        ),
      );
      h = await publishing([fakeTransport()], cache: cache);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();

      expect(cache.aliases, [
        (local: keyOf('a').encoded, server: server.encoded),
      ]);
      expect(
        cache.seenAtAlias.single,
        (publishCalls: 1, state: 'completed'),
        reason:
            'the alias applies after the publisher answered, never at '
            'upload completion',
      );
      expect(
        job.snapshot.state,
        PublishJobState.completed(Uint8List.fromList([7])),
      );
      expect(job.snapshot.aliasesApplied, isTrue);
      expect(recorder.whereOp(PublishOp.aliasApplied), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          jobId: job.id,
          itemId: 'a',
          mediaKey: keyOf('a'),
          fields: {'result': 'aliased'},
        ),
      ]);
      expect(recorder.whereOp(PublishOp.outcome), [
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {'outcome': 'published', 'retryable': false, 'serverKeys': 1},
        ),
      ]);
    });

    test('reports a server key whose item is unknown, and one whose local '
        'key held nothing, and still applies the rest', () async {
      final cache = _AliasRecorder(answer: false);
      final h = await publishing([fakeTransport()], cache: cache);
      h.transfers.registerPublisher(
        publisherId,
        FakePublisher()..answerWith(
          PublishOutcome.published(
            serverKeys: const {
              'a': server,
              'ghost': MediaKey.remote('server-ghost'),
            },
          ),
        ),
      );
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      expect(cache.aliases, hasLength(1));
      expect(
        [
          for (final event in recorder.whereOp(PublishOp.aliasApplied))
            event.fields['result'],
        ],
        ['nothingHeld', 'unknownItem'],
      );
      expect(job.snapshot.aliasesApplied, isTrue);
    });

    test(
      'an alias that throws is a warning, and the job stays completed',
      () async {
        final cache = _AliasRecorder(error: StateError('disk'));
        final h = await publishing([fakeTransport()], cache: cache);
        h.transfers.registerPublisher(
          publisherId,
          FakePublisher()..answerWith(
            PublishOutcome.published(serverKeys: const {'a': server}),
          ),
        );
        final job = h.transfers.publish(
          requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
        );
        await pumpEventQueue();
        expect(recorder.whereOp(PublishOp.aliasApplied), [
          isMpxEvent(
            level: MpxEventLevel.warning,
            fields: {'result': 'failed'},
          ),
        ]);
        expect(job.snapshot.state, const PublishJobState.completed(null));
      },
    );

    test(
      'a facade without a bytes cache reports that no alias was made',
      () async {
        final h = await publishing([fakeTransport()]);
        h.transfers.registerPublisher(
          publisherId,
          FakePublisher()..answerWith(
            PublishOutcome.published(serverKeys: const {'a': server}),
          ),
        );
        final job = h.transfers.publish(
          requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
        );
        await pumpEventQueue();
        expect(
          recorder.whereOp(PublishOp.aliasApplied).single.fields['result'],
          'noCache',
        );
        expect(job.snapshot.aliasesApplied, isTrue);
      },
    );
  });

  group('reuploadItems', () {
    test('drops the reuse entry, uploads the item again and publishes again '
        'with the same key', () async {
      final transport = fakeTransport();
      final publisher = FakePublisher()
        ..answerWith(PublishOutcome.reuploadItems(const ['a']));
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final file = preparedOf(10);
      final job = h.transfers.publish(
        requestOf([
          itemOf('a', PublishSource.prepared(file), fingerprint: 'fp-a'),
          itemOf('r', const PublishSource.remote()),
        ]),
      );
      await pumpEventQueue();

      expect(publisher.calls, hasLength(2));
      expect(
        publisher.calls[1].idempotencyKey,
        publisher.calls[0].idempotencyKey,
      );
      expect(transport.opens, hasLength(2), reason: 'item a went again');
      expect(transport.opens.map((open) => open.info.size), [10, 10]);
      expect(
        publisher.calls[1].items['a']!.file,
        isNot(publisher.calls[0].items['a']!.file),
      );
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(recorder.whereOp(ReuseOp.invalidated), [
        isMpxEvent(
          itemId: 'a',
          jobId: job.id,
          fields: {'why': 'reuploadItems'},
        ),
      ]);
      expect(
        recorder.whereOp(PublishOp.outcome).first,
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {
            'outcome': 'reuploadItems',
            'retryable': false,
            'serverKeys': 0,
            'items': 1,
          },
        ),
      );
    });

    test('an item the reuse table answered is looked up no more and '
        'uploads', () async {
      final transport = fakeTransport();
      final h = await publishing([transport]);
      final file = preparedOf(10);
      PublishItem item() =>
          itemOf('a', PublishSource.prepared(file), fingerprint: 'fp-hit');
      h.transfers.registerPublisher(publisherId, FakePublisher());
      h.transfers.publish(requestOf([item()]));
      await pumpEventQueue();
      expect(transport.opens, hasLength(1));

      final publisher = FakePublisher()
        ..answerWith(PublishOutcome.reuploadItems(const ['a']));
      h.transfers.registerPublisher(publisherId, publisher);
      final again = h.transfers.publish(requestOf([item()]));
      await pumpEventQueue();
      expect(transport.opens, hasLength(2));
      expect(publisher.calls, hasLength(2));
      expect(publisher.calls[0].items['a']!.file, RemoteRef('fake-1'));
      expect(publisher.calls[1].items['a']!.file, RemoteRef('fake-2'));
      expect(again.snapshot.state, const PublishJobState.completed(null));
    });

    test('a second one fails the job at the publish stage', () async {
      final transport = fakeTransport();
      final publisher = FakePublisher()
        ..answerWith(PublishOutcome.reuploadItems(const ['a']))
        ..answerWith(PublishOutcome.reuploadItems(const ['a']));
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      expect(publisher.calls, hasLength(2));
      expect(transport.opens, hasLength(2));
      expect(
        job.snapshot.state,
        const PublishJobState.failed(
          stage: PublishStage.publish,
          reason: 'reuploadRefused',
          retryable: false,
        ),
      );
      expect(recorder.whereOp(PublishOp.reuploadRefused), [
        isMpxEvent(level: MpxEventLevel.error, jobId: job.id),
      ]);
    });

    test('the honoured answer survives a kill', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      publisher.answer(PublishOutcome.reuploadItems(const ['a']));
      await pumpEventQueue();
      await h.settle();
      await h.kill();

      final second = FakePublisher()
        ..answerWith(PublishOutcome.reuploadItems(const ['a']));
      h.transfers.registerPublisher(publisherId, second);
      await pumpEventQueue();
      expect(
        h.transfers.publishJob(job.id)!.snapshot.state,
        isA<PublishJobState$Failed>().having(
          (state) => state.reason,
          'reason',
          'reuploadRefused',
        ),
      );
    });
  });

  group('rejected', () {
    test('fails the job at the publish stage; its retry calls the publisher '
        'once more and uploads nothing', () async {
      final transport = fakeTransport();
      final publisher = FakePublisher()
        ..answerWith(
          const PublishOutcome.rejected(reason: 'slowMode', retryable: true),
        );
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      expect(
        job.snapshot.state,
        const PublishJobState.failed(
          stage: PublishStage.publish,
          reason: 'slowMode',
          retryable: true,
        ),
      );
      expect(recorder.whereOp(PublishOp.outcome), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {'outcome': 'rejected', 'retryable': true, 'serverKeys': 0},
        ),
      ]);

      expect(job.retry(), isTrue);
      await pumpEventQueue();
      expect(publisher.calls, hasLength(2));
      expect(
        publisher.calls[1].idempotencyKey,
        publisher.calls[0].idempotencyKey,
      );
      expect(transport.opens, hasLength(1), reason: 'nothing uploads again');
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(recorder.whereOp(PublishOp.retry), [
        isMpxEvent(
          level: MpxEventLevel.info,
          jobId: job.id,
          fields: {'stage': 'publish', 'items': 0},
        ),
      ]);
    });

    test('retry answers false for a running or a completed job', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(requestOf(const []));
      await pumpEventQueue();
      expect(job.retry(), isFalse);
      publisher.answer();
      await pumpEventQueue();
      expect(job.retry(), isFalse);
      expect(publisher.calls, hasLength(1));
    });
  });

  group('whole-job policy', () {
    test('a retry after one failed item uploads only that item, from the '
        'parts it sent', () async {
      final transport = fakeTransport(partSize: 10, bytesInFlight: 10)
        ..failPart(
          2,
          error: const UploadTransportException('gone', status: 403),
        );
      final publisher = FakePublisher();
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([
          itemOf('big', PublishSource.prepared(preparedOf(30))),
          itemOf('small', PublishSource.prepared(preparedOf(5))),
        ]),
      );
      await pumpEventQueue();
      expect(
        job.snapshot.state,
        isA<PublishJobState$Failed>().having(
          (state) => state.stage,
          'stage',
          PublishStage.upload,
        ),
      );
      expect(publisher.calls, isEmpty);
      final opensBefore = transport.opens.length;
      final sentBefore = transport.sent.length;

      expect(job.retry(), isTrue);
      await pumpEventQueue();
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(publisher.calls.single.items.keys, ['big', 'small']);
      expect(transport.finishes, hasLength(2), reason: 'small went once');
      expect(transport.opens.length - opensBefore, 1);
      expect(
        transport.sent.skip(sentBefore).map((part) => part.offset),
        [20],
        reason: 'only the part that failed is sent again',
      );
      expect(recorder.whereOp(PublishOp.retry).single.fields, {
        'stage': 'upload',
        'items': 1,
      });
    });

    test(
      'a retry after a failed preparation prepares only that item',
      () async {
        var prepared = 0;
        final preparation = FakeMediaPreparation(
          onPrepare: (handle) =>
              prepared++ == 0 ? handle.fail('noSpace') : handle.complete(),
        );
        final transport = fakeTransport();
        final h = await publishing([transport], preparation: preparation);
        h.transfers.registerPublisher(publisherId, FakePublisher());
        final job = h.transfers.publish(
          requestOf([
            itemOf(
              'p',
              PublishSource.prepare(
                inputOf(50),
                const PreparationIntent.photo(),
              ),
            ),
            itemOf('f', PublishSource.prepared(preparedOf(5))),
          ]),
        );
        await pumpEventQueue();
        expect(job.snapshot.state, isA<PublishJobState$Failed>());
        expect(job.retryItem('f'), isFalse, reason: 'f did not fail');
        expect(job.retryItem('p'), isTrue);
        await pumpEventQueue();
        expect(preparation.handles, hasLength(2));
        expect(transport.finishes, hasLength(2));
        expect(job.snapshot.state, const PublishJobState.completed(null));
      },
    );
  });

  group('per-item policy', () {
    PublishRequest perItem(List<PublishItem> items) => PublishRequest(
      items: items,
      payload: Uint8List(0),
      publisher: publisherId,
      failurePolicy: PublishFailurePolicy.perItem,
    );

    test('a failed item waits while the rest upload, and the job publishes '
        'once it is removed', () async {
      final transport = fakeTransport()
        ..failOpen(error: const UploadTransportException('no', status: 403));
      final publisher = FakePublisher();
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        perItem([
          itemOf('bad', PublishSource.prepared(preparedOf(10))),
          itemOf('good', PublishSource.prepared(preparedOf(10))),
        ]),
      );
      await pumpEventQueue();
      expect(job.snapshot.item('bad')!.state, isA<PublishItemState$Failed>());
      expect(
        job.snapshot.item('good')!.state,
        isA<PublishItemState$Uploaded>(),
      );
      expect(job.snapshot.state, const PublishJobState.uploading());
      expect(publisher.calls, isEmpty);

      expect(job.removeItem('bad'), isTrue);
      await pumpEventQueue();
      expect(publisher.calls.single.items.keys, ['good']);
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(recorder.whereOp(PublishOp.itemRemoved), [
        isMpxEvent(
          level: MpxEventLevel.info,
          jobId: job.id,
          itemId: 'bad',
          mediaKey: keyOf('bad'),
          fields: {'by': 'host'},
        ),
      ]);
    });

    test(
      'a retried item uploads again and the job publishes every item',
      () async {
        final transport = fakeTransport()
          ..failOpen(error: const UploadTransportException('no', status: 403));
        final publisher = FakePublisher();
        final h = await publishing([transport]);
        h.transfers.registerPublisher(publisherId, publisher);
        final job = h.transfers.publish(
          perItem([
            itemOf('bad', PublishSource.prepared(preparedOf(10))),
            itemOf('good', PublishSource.prepared(preparedOf(10))),
          ]),
        );
        await pumpEventQueue();
        expect(job.retryItem('bad'), isTrue);
        await pumpEventQueue();
        expect(publisher.calls.single.items.keys, ['bad', 'good']);
        expect(transport.finishes, hasLength(2));
        expect(
          recorder.whereOp(PublishOp.retry).single,
          isMpxEvent(itemId: 'bad', fields: {'stage': 'upload', 'items': 1}),
        );
      },
    );

    test('the last item is not removed, nor an item of an ended job', () async {
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, FakePublisher());
      final job = h.transfers.publish(
        perItem([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      expect(job.removeItem('a'), isFalse);
      expect(job.removeItem('nope'), isFalse);
      await pumpEventQueue();
      expect(job.snapshot.state, const PublishJobState.completed(null));
    });
  });

  group('kills', () {
    test(
      'a kill after rejected comes back failed at the publish stage',
      () async {
        final publisher = FakePublisher()
          ..answerWith(const PublishOutcome.rejected(reason: 'tooLong'));
        final h = await publishing([fakeTransport()]);
        h.transfers.registerPublisher(publisherId, publisher);
        final job = h.transfers.publish(
          requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
        );
        await pumpEventQueue();
        await h.settle();
        await h.kill();
        final second = FakePublisher();
        h.transfers.registerPublisher(publisherId, second);
        await pumpEventQueue();
        expect(
          h.transfers.publishJob(job.id)!.snapshot.state,
          const PublishJobState.failed(
            stage: PublishStage.publish,
            reason: 'tooLong',
            retryable: false,
          ),
        );
        expect(second.calls, isEmpty);
      },
    );

    test('a kill after published but before the alias applies the alias at '
        'the next start and never publishes again', () async {
      final cache = _AliasRecorder(hold: true);
      final publisher = FakePublisher()
        ..answerWith(PublishOutcome.published(serverKeys: const {'a': server}));
      final h = await publishing([fakeTransport()], cache: cache);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      expect(cache.aliases, hasLength(1));
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(job.snapshot.aliasesApplied, isFalse);
      await h.settle();
      cache.hold = false;
      await h.kill();

      final second = FakePublisher();
      h.transfers.registerPublisher(publisherId, second);
      await pumpEventQueue();
      expect(second.calls, isEmpty);
      expect(publisher.calls, hasLength(1));
      expect(cache.aliases, hasLength(2));
      expect(cache.aliases.toSet(), {
        (local: keyOf('a').encoded, server: server.encoded),
      });
      final after = h.transfers.publishJob(job.id)!.snapshot;
      expect(after.state, const PublishJobState.completed(null));
      expect(after.aliasesApplied, isTrue);

      await h.settle();
      await h.restart();
      await pumpEventQueue();
      expect(cache.aliases, hasLength(2), reason: 'applied once, then kept');
    });

    test('a whole-job failure retried after a restart keeps the uploads it '
        'journaled', () async {
      final transport = fakeTransport()
        ..failOpen(error: const UploadTransportException('no', status: 403));
      final h = await publishing([transport]);
      final job = h.transfers.publish(
        requestOf([
          itemOf('bad', PublishSource.prepared(preparedOf(10))),
          itemOf('good', PublishSource.prepared(preparedOf(10))),
        ]),
      );
      await pumpEventQueue();
      await h.settle();
      await h.kill();
      final publisher = FakePublisher();
      h.transfers.registerPublisher(publisherId, publisher);
      expect(h.transfers.publishJob(job.id)!.retry(), isTrue);
      await pumpEventQueue();
      expect(transport.finishes, hasLength(2));
      expect(publisher.calls.single.items.keys, ['bad', 'good']);
    });
  });

  test('no outcome event carries the rejection reason or a key', () async {
    final h = await publishing([fakeTransport()]);
    h.transfers.registerPublisher(
      publisherId,
      FakePublisher()
        ..answerWith(const PublishOutcome.rejected(reason: 'secret-reason')),
    );
    h.transfers.publish(
      requestOf([
        itemOf('a', PublishSource.prepared(preparedOf(10))),
      ], idempotencyKey: 'secret-key'),
    );
    await pumpEventQueue();
    for (final event in recorder.whereCategory('publish')) {
      if (event.op == PublishOp.itemStage) continue;
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('secret')));
      }
    }
  });

  test('outcomes compare by value', () {
    expect(
      PublishOutcome.reuploadItems(const ['a', 'b']),
      PublishOutcome.reuploadItems(const ['b', 'a']),
    );
    expect(
      const PublishOutcome.rejected(reason: 'x', retryable: true),
      const PublishOutcome.rejected(reason: 'x', retryable: true),
    );
    expect(
      const PublishOutcome.rejected(reason: 'x'),
      isNot(const PublishOutcome.rejected(reason: 'x', retryable: true)),
    );
  });
}

typedef _Alias = ({String local, String server});

/// A bytes cache that only records its aliases, in order, with what
/// [onAlias] saw at each; [hold] keeps each one waiting forever, as a kill
/// during the alias would.
final class _AliasRecorder implements IBytesStore {
  _AliasRecorder({
    this.onAlias,
    this.answer = true,
    this.error,
    this.hold = false,
  });

  final ({int publishCalls, String state}) Function()? onAlias;
  final bool answer;
  final Object? error;
  bool hold;

  final List<_Alias> aliases = [];
  final List<({int publishCalls, String state})> seenAtAlias = [];

  @override
  Future<bool> alias(BytesCacheKey local, BytesCacheKey server) {
    aliases.add((local: local.value, server: server.value));
    if (onAlias case final seen?) seenAtAlias.add(seen());
    if (hold) return Completer<bool>().future;
    if (error case final error?) return Future.error(error);
    return Future.value(answer);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
