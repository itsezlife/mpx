import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  /// Three jobs: two of chat 1 through [publisherId] (one completed), one of
  /// chat 12 through another publisher, waiting for it.
  Future<(UploadsHarness, List<PublishJob>)> threeJobs() async {
    final h = await publishing([fakeTransport()]);
    h.transfers.registerPublisher(publisherId, FakePublisher());
    final jobs = [
      h.transfers.publish(requestOf(const [], tag: 'chat:1:a')),
      h.transfers.publish(
        requestOf([
          itemOf('x', PublishSource.prepared(preparedOf(10))),
        ], tag: 'chat:1:b'),
      ),
      h.transfers.publish(
        requestOf(const [], tag: 'chat:12:c', publisher: 'other'),
      ),
    ];
    await pumpEventQueue();
    return (h, jobs);
  }

  Future<List<String?>> tagsOf(
    Transfers transfers, [
    PublishJobFilter filter = const PublishJobFilter(),
  ]) async => [
    for (final job in await transfers.watchJobs(filter).first) job.tag,
  ];

  Future<void> expectFilters(Transfers transfers) async {
    expect(await tagsOf(transfers), ['chat:1:a', 'chat:1:b', 'chat:12:c']);
    expect(await tagsOf(transfers, const PublishJobFilter(tag: 'chat:1:b')), [
      'chat:1:b',
    ]);
    expect(
      await tagsOf(transfers, const PublishJobFilter(tagPrefix: 'chat:1:')),
      ['chat:1:a', 'chat:1:b'],
    );
    expect(
      await tagsOf(transfers, const PublishJobFilter(publisher: 'other')),
      ['chat:12:c'],
    );
    expect(
      await tagsOf(
        transfers,
        PublishJobFilter(
          state: (state) => state is PublishJobState$AwaitingPublisher,
        ),
      ),
      ['chat:12:c'],
    );
    expect(
      await tagsOf(
        transfers,
        PublishJobFilter(
          tagPrefix: 'chat:1',
          state: (state) => state is PublishJobState$Completed,
        ),
      ),
      ['chat:1:a', 'chat:1:b'],
    );
  }

  test(
    'watchJobs passes jobs by tag, tag prefix, publisher and state',
    () async {
      final (h, _) = await threeJobs();
      await expectFilters(h.transfers);
    },
  );

  test('after a restart watchJobs answers from the journal', () async {
    final (h, _) = await threeJobs();
    await h.settle();
    final transfers = await h.restart();
    await expectFilters(transfers);
  });

  test('after a kill watchJobs answers from the journal', () async {
    final (h, _) = await threeJobs();
    await h.settle();
    final transfers = await h.kill();
    await expectFilters(transfers);
  });

  test(
    'watchJobs gives the list again as a job moves, with its progress',
    () async {
      final transport = fakeTransport(holdParts: true);
      final h = await publishing([transport]);
      final lists = <List<PublishJobSnapshot>>[];
      h.transfers
          .watchJobs(const PublishJobFilter(tagPrefix: 'chat:1:'))
          .listen(lists.add);
      await pumpEventQueue();
      expect(lists.single, isEmpty);

      h.transfers.publish(
        requestOf([
          itemOf('x', PublishSource.prepared(preparedOf(10))),
        ], tag: 'chat:1:m'),
      );
      h.transfers.publish(requestOf(const [], tag: 'chat:2:m'));
      await pumpEventQueue();
      expect(lists.last.single.tag, 'chat:1:m');
      expect(lists.last.single.progress, 0);

      transport.ack(transport.held.single);
      await pumpEventQueue();
      expect(
        lists.last.single.state,
        const PublishJobState.awaitingPublisher(),
      );
      expect(lists.last.single.progress, closeTo(0.95, 1e-9));
      h.transfers.registerPublisher(publisherId, FakePublisher());
      await pumpEventQueue();
      expect(lists.last.single.state, const PublishJobState.completed(null));
      expect(lists.last.single.progress, 1);
      for (var i = 1; i < lists.length; i++) {
        expect(lists[i], isNot(lists[i - 1]), reason: 'a list given twice');
      }
    },
  );

  test('watchJobs ends when the facade is disposed', () async {
    final h = await publishing([fakeTransport()]);
    var done = false;
    h.transfers.watchJobs().listen(null, onDone: () => done = true);
    await pumpEventQueue();
    await h.transfers.dispose();
    await pumpEventQueue();
    expect(done, isTrue);
  });
}
