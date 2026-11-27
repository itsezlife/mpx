import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

const String _group = 'chat-1';

/// A request whose payload is [mark], so a publisher call tells the jobs
/// apart.
PublishRequest _request(
  int mark,
  List<PublishItem> items, {
  String? group = _group,
  bool hold = false,
  String? tag,
}) => PublishRequest(
  items: items,
  payload: Uint8List.fromList([mark]),
  publisher: publisherId,
  orderingGroup: group,
  hold: hold,
  tag: tag,
);

PublishItem _prepare(String id) => itemOf(
  id,
  PublishSource.prepare(inputOf(10), const PreparationIntent.photo()),
);

PublishItem _prepared(String id) =>
    itemOf(id, PublishSource.prepared(preparedOf(10)));

/// The payload marks of [publisher]'s calls, in order.
List<int> _marks(FakePublisher publisher) => [
  for (final call in publisher.calls) call.payload.single,
];

/// The ids of the uploads that carry [key] now.
Future<List<TransferId>> _uploadsOf(Transfers transfers, MediaKey key) async =>
    [
      for (final job in await transfers.watch().first)
        if (job.key == key) job.id,
    ];

void main() {
  late RecordingDiagnostics recorder;

  setUp(() => recorder = RecordingDiagnostics.install());

  group('ordering group', () {
    test('three jobs whose uploads finish in reverse order publish 1, 2, '
        '3, each after the one before answered', () async {
      final preparation = FakeMediaPreparation();
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()], preparation: preparation);
      h.transfers.registerPublisher(publisherId, publisher);
      final jobs = [
        for (final mark in [1, 2, 3])
          h.transfers.publish(_request(mark, [_prepare('i$mark')])),
      ];
      await pumpEventQueue();
      for (final handle in preparation.handles.reversed.toList()) {
        handle.complete();
        await pumpEventQueue();
      }
      expect(_marks(publisher), [1], reason: '2 and 3 wait for 1');
      expect(jobs[2].snapshot.state, const PublishJobState.publishing());
      expect(recorder.whereOp(PublishOp.groupWait), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          jobId: jobs[2].id,
          fields: {'ahead': 2},
        ),
        isMpxEvent(jobId: jobs[1].id, fields: {'ahead': 1}),
      ]);

      publisher.answer();
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2]);
      publisher.answer();
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2, 3]);
      publisher.answer();
      await pumpEventQueue();
      for (final job in jobs) {
        expect(job.snapshot.state, const PublishJobState.completed(null));
      }
    });

    test('a failed job does not hold the group, and retried it publishes '
        'after the jobs made after it', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final jobs = [
        for (final mark in [1, 2, 3])
          h.transfers.publish(_request(mark, [_prepared('i$mark')])),
      ];
      await pumpEventQueue();
      publisher.answer();
      await pumpEventQueue();
      publisher.answer(
        const PublishOutcome.rejected(reason: 'busy', retryable: true),
      );
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2, 3], reason: '3 goes on past 2');

      expect(jobs[1].retry(), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2, 3], reason: '2 is behind 3 now');
      expect(
        recorder.whereOp(PublishOp.groupWait).last,
        isMpxEvent(jobId: jobs[1].id, fields: {'ahead': 1}),
      );
      publisher.answer();
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2, 3, 2]);
      publisher.answer();
      await pumpEventQueue();
      expect(jobs[1].snapshot.state, const PublishJobState.completed(null));
    });

    test('jobs of other groups or of none do not wait', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      h.transfers
        ..publish(_request(1, [_prepared('a')]))
        ..publish(_request(2, [_prepared('b')], group: 'chat-2'))
        ..publish(_request(3, [_prepared('c')], group: null));
      await pumpEventQueue();
      expect(_marks(publisher), unorderedEquals([1, 2, 3]));
      expect(recorder.whereOp(PublishOp.groupWait), isEmpty);
    });

    test('a cancelled job, a held one not committed and one awaiting its '
        'owner hold no one', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final first = h.transfers.publish(_request(1, [_prepared('a')]));
      final held = h.transfers.publish(
        _request(2, [_prepared('b')], hold: true),
      );
      final emptied = h.transfers.publish(
        _request(3, [_prepared('c')], hold: true),
      );
      expect(emptied.commit(), isTrue);
      final last = h.transfers.publish(_request(4, [_prepared('d')]));
      await pumpEventQueue();
      expect(_marks(publisher), [1]);
      expect(emptied.removeItem('c'), isTrue);
      expect(first.cancel(), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [1, 4]);
      expect(held.snapshot.held, isTrue);

      expect(held.commit(), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [1, 4], reason: 'committed, it joins the end');
      publisher
        ..answer() // the cancelled job's call, which the engine ignores
        ..answer();
      await pumpEventQueue();
      expect(_marks(publisher), [1, 4, 2]);
      expect(last.snapshot.state, const PublishJobState.completed(null));
    });
  });

  group('hold and commit', () {
    test('a held job prepares and uploads but publishes only on commit, '
        'with the committed payload', () async {
      final publisher = FakePublisher();
      final preparation = FakeMediaPreparation(onPrepare: (h) => h.complete());
      final h = await publishing([fakeTransport()], preparation: preparation);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        _request(1, [_prepare('a'), _prepared('b')], hold: true, tag: 't'),
      );
      await pumpEventQueue();
      expect(job.snapshot.held, isTrue);
      expect(job.snapshot.state, const PublishJobState.uploading());
      expect(job.snapshot.items.map((item) => item.state.name), [
        'uploaded',
        'uploaded',
      ]);
      expect(publisher.calls, isEmpty);

      expect(job.commit(payload: Uint8List.fromList([9])), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [9]);
      expect(job.snapshot.held, isFalse);
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(recorder.whereOp(PublishOp.committed), [
        isMpxEvent(
          level: MpxEventLevel.info,
          jobId: job.id,
          tag: 't',
          fields: {'items': 2},
        ),
      ]);
    });

    test('before commit every verb applies; once publishing only removeItem '
        'and cancel', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        _request(1, [_prepared('a'), _prepared('b')], hold: true),
      );
      expect(job.addItem(_prepared('c')), isTrue);
      expect(job.reorder(['c', 'a', 'b']), isTrue);
      expect(job.removeItem('a'), isTrue);
      expect(job.setPayload(Uint8List.fromList([5])), isTrue);
      expect(() => job.addItem(_prepared('b')), throwsArgumentError);
      expect(() => job.reorder(['b']), throwsArgumentError);
      await pumpEventQueue();
      expect(publisher.calls, isEmpty);

      expect(job.commit(), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [5]);
      expect(publisher.calls.single.items.keys, ['c', 'b']);
      expect(job.commit(), isFalse);
      expect(job.addItem(_prepared('d')), isFalse);
      expect(job.reorder(['b', 'c']), isFalse);
      expect(job.setPayload(Uint8List(1)), isFalse);
      expect(job.removeItem('b'), isTrue, reason: 'during the request');
      expect(job.cancel(), isTrue);
      expect(h.transfers.publishJob(job.id), isNull);
    });

    test('a job made without hold takes no item, order or payload change, '
        'and no commit', () async {
      final h = await publishing([fakeTransport()]);
      final job = h.transfers.publish(_request(1, [_prepared('a')]));
      expect(job.addItem(_prepared('b')), isFalse);
      expect(job.reorder(['a']), isFalse);
      expect(job.setPayload(Uint8List(1)), isFalse);
      expect(job.commit(), isFalse);
    });

    test('cancel before commit drops all uploaded state and the job', () async {
      final h = await publishing([fakeTransport()]);
      final job = h.transfers.publish(
        _request(1, [_prepared('a')], hold: true, tag: 't'),
      );
      final lists = <List<PublishJobSnapshot>>[];
      final watching = h.transfers.watchJobs().listen(lists.add);
      addTearDown(watching.cancel);
      await pumpEventQueue();
      expect(job.snapshot.items.single.state.name, 'uploaded');
      expect(await _uploadsOf(h.transfers, keyOf('a')), isNotEmpty);

      expect(job.cancel(), isTrue);
      await pumpEventQueue();
      expect(await _uploadsOf(h.transfers, keyOf('a')), isEmpty);
      expect(h.transfers.publishJob(job.id), isNull);
      expect(lists.last, isEmpty);
      expect(job.cancel(), isFalse);
      expect(recorder.whereOp(PublishOp.cancelled), [
        isMpxEvent(
          level: MpxEventLevel.info,
          jobId: job.id,
          tag: 't',
          fields: {'by': 'owner', 'items': 1},
        ),
      ]);
    });

    test('cancel during the upload stops it and ends the watchers', () async {
      final transport = fakeTransport(holdParts: true);
      final h = await publishing([transport]);
      final job = h.transfers.publish(_request(1, [_prepared('a')]));
      final done = job.watch().toList();
      await pumpEventQueue();
      expect(await _uploadsOf(h.transfers, keyOf('a')), hasLength(1));
      expect(job.cancel(), isTrue);
      await pumpEventQueue();
      expect(await _uploadsOf(h.transfers, keyOf('a')), isEmpty);
      await expectLater(done, completes);
      expect(
        recorder.whereOp(SchedulerOp.cancelled).single.fields['by'],
        'owner',
      );
    });
  });

  group('item cancel', () {
    test('removing one of three items publishes the other two', () async {
      final publisher = FakePublisher();
      final transport = fakeTransport(holdParts: true);
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        _request(1, [_prepared('a'), _prepared('b'), _prepared('c')], tag: 't'),
      );
      final b = job.watchItem('b').toList();
      await pumpEventQueue();
      expect(job.removeItem('b'), isTrue);
      await pumpEventQueue();
      expect((await b).last.state, const PublishItemState.removed());
      expect(await _uploadsOf(h.transfers, keyOf('b')), isEmpty);
      expect(job.snapshot.items.map((item) => item.itemId), ['a', 'c']);

      transport.holdParts = false;
      for (final _ in transport.held) {
        transport.ack(transport.held.first);
      }
      await pumpEventQueue();
      expect(publisher.calls.single.items.keys, ['a', 'c']);
      expect(recorder.whereOp(PublishOp.itemRemoved), [
        isMpxEvent(
          level: MpxEventLevel.info,
          jobId: job.id,
          itemId: 'b',
          mediaKey: keyOf('b'),
          tag: 't',
          fields: {'by': 'host'},
        ),
      ]);
    });

    test('a cancel of one item upload removes the item, by the cell, and '
        'the rest publish', () async {
      final publisher = FakePublisher();
      final transport = fakeTransport(holdParts: true);
      final h = await publishing([transport]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        _request(1, [_prepared('a'), _prepared('b')]),
      );
      await pumpEventQueue();
      final upload = (await _uploadsOf(h.transfers, keyOf('a'))).single;
      expect(h.transfers.cancel(upload), isTrue);
      await pumpEventQueue();
      expect(job.snapshot.items.map((item) => item.itemId), ['b']);
      expect(job.snapshot.state, isNot(isA<PublishJobState$Failed>()));

      transport.holdParts = false;
      for (final _ in transport.held) {
        transport.ack(transport.held.first);
      }
      await pumpEventQueue();
      expect(publisher.calls.single.items.keys, ['b']);
      expect(
        recorder.whereOp(PublishOp.itemRemoved).single,
        isMpxEvent(itemId: 'a', fields: {'by': 'cell'}),
      );
    });

    test(
      'removing the last item leaves the job awaiting its owner, '
      'publishing nothing across a restart, until the owner commits',
      () async {
        final publisher = FakePublisher();
        final transport = fakeTransport(holdParts: true);
        final h = await publishing([transport]);
        h.transfers.registerPublisher(publisherId, publisher);
        final job = h.transfers.publish(
          _request(1, [_prepared('a')], tag: 't'),
        );
        await pumpEventQueue();
        expect(job.removeItem('a'), isTrue);
        await pumpEventQueue();
        expect(job.snapshot.state, const PublishJobState.awaitingOwner());
        expect(job.snapshot.items, isEmpty);
        expect(publisher.calls, isEmpty);
        expect(recorder.whereOp(PublishOp.awaitingOwner), [
          isMpxEvent(level: MpxEventLevel.info, jobId: job.id, tag: 't'),
        ]);
        expect(h.transfers.debugSnapshot().publish!.awaitingOwner, [job.id]);

        await h.settle();
        await h.kill();
        final after = FakePublisher();
        h.transfers.registerPublisher(publisherId, after);
        await pumpEventQueue();
        final again = h.transfers.publishJob(job.id)!;
        final listed = await h.transfers
            .watchJobs(const PublishJobFilter(tagPrefix: 't'))
            .first;
        expect(listed.single.state, const PublishJobState.awaitingOwner());
        expect(after.calls, isEmpty);

        expect(again.commit(), isTrue);
        await pumpEventQueue();
        expect(after.calls.single.items, isEmpty);
        expect(again.snapshot.state, const PublishJobState.completed(null));
      },
    );

    test('an owner may cancel a job left with no items', () async {
      final h = await publishing([fakeTransport(holdParts: true)]);
      final job = h.transfers.publish(_request(1, [_prepared('a')]));
      await pumpEventQueue();
      job.removeItem('a');
      expect(job.cancel(), isTrue);
      expect(h.transfers.publishJob(job.id), isNull);
    });

    test('a held job left with no items takes new ones and goes on', () async {
      final publisher = FakePublisher();
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(
        _request(1, [_prepared('a')], hold: true),
      );
      job.removeItem('a');
      expect(job.snapshot.state, const PublishJobState.awaitingOwner());
      expect(job.addItem(_prepared('b')), isTrue);
      await pumpEventQueue();
      expect(job.snapshot.state, const PublishJobState.uploading());
      expect(job.commit(), isTrue);
      await pumpEventQueue();
      expect(publisher.calls.single.items.keys, ['b']);
    });

    test('a job made with no items publishes at once', () async {
      final publisher = FakePublisher();
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final job = h.transfers.publish(_request(1, const []));
      await pumpEventQueue();
      expect(_marks(publisher), [1]);
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(recorder.whereOp(PublishOp.awaitingOwner), isEmpty);
    });
  });

  group('kills', () {
    test('group order survives a kill, a retried job keeping its place at '
        'the end', () async {
      final publisher = FakePublisher(hold: true);
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher(publisherId, publisher);
      final jobs = [
        for (final mark in [1, 2, 3])
          h.transfers.publish(_request(mark, [_prepared('i$mark')])),
      ];
      await pumpEventQueue();
      publisher.answer(
        const PublishOutcome.rejected(reason: 'busy', retryable: true),
      );
      await pumpEventQueue();
      expect(jobs[0].retry(), isTrue);
      await pumpEventQueue();
      expect(_marks(publisher), [1, 2]);
      await h.settle();
      await h.kill();

      final after = FakePublisher(hold: true);
      h.transfers.registerPublisher(publisherId, after);
      await pumpEventQueue();
      expect(_marks(after), [2], reason: "2's attempt is made again");
      after.answer();
      await pumpEventQueue();
      expect(_marks(after), [2, 3]);
      after.answer();
      await pumpEventQueue();
      expect(_marks(after), [2, 3, 1]);
    });

    test('the hold phase survives a kill, and so does a commit', () async {
      final h = await publishing([fakeTransport()]);
      final job = h.transfers.publish(
        _request(1, [_prepared('a')], hold: true),
      );
      expect(job.setPayload(Uint8List.fromList([4])), isTrue);
      await pumpEventQueue();
      await h.settle();
      await h.kill();
      final publisher = FakePublisher();
      h.transfers.registerPublisher(publisherId, publisher);
      await pumpEventQueue();
      final again = h.transfers.publishJob(job.id)!;
      expect(again.snapshot.held, isTrue);
      expect(publisher.calls, isEmpty);

      // Committed with no publisher registered, then killed.
      await h.restart();
      final held = h.transfers.publishJob(job.id)!;
      expect(held.commit(), isTrue);
      await pumpEventQueue();
      await h.settle();
      await h.kill();
      final last = FakePublisher();
      h.transfers.registerPublisher(publisherId, last);
      await pumpEventQueue();
      expect(_marks(last), [4]);
    });
  });

  test('no event carries the payload or a path', () async {
    final h = await publishing([fakeTransport()]);
    h.transfers.registerPublisher(publisherId, FakePublisher());
    final job = h.transfers.publish(
      _request(1, [_prepared('a'), _prepared('b')], hold: true),
    );
    job
      ..removeItem('a')
      ..commit(payload: Uint8List.fromList([7, 7, 7]));
    await pumpEventQueue();
    for (final event in recorder.events) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('/prepared/')));
        expect('$value', isNot(contains('7, 7, 7')));
      }
    }
  });
}
