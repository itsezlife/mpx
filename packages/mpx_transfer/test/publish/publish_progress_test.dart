import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  test('the weights default to 30 % for a video preparation, 2 % for a '
      'photo or a file and 5 % for the publish', () {
    const weights = PublishProgressWeights.standard;
    expect(weights.videoPreparation, 0.3);
    expect(weights.photoPreparation, 0.02);
    expect(weights.filePreparation, 0.02);
    expect(weights.publish, 0.05);
  });

  test('a video item prepares through 30 % of its weight, uploads through '
      'the rest, and the publish takes the last 5 % of the job', () async {
    final preparation = FakeMediaPreparation();
    final publisher = FakePublisher(hold: true);
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(inputOf(1000), const PreparationIntent.video()),
        ),
      ]),
    );
    await pumpEventQueue();
    expect(job.snapshot.progress, 0);

    preparation.last.report(0.5);
    await pumpEventQueue();
    expect(job.snapshot.item('v')!.progress, closeTo(0.15, 1e-9));
    expect(job.snapshot.progress, closeTo(0.95 * 0.15, 1e-9));

    preparation.last.complete();
    await pumpEventQueue();
    expect(job.snapshot.item('v')!.progress, closeTo(0.3, 1e-9));
    expect(job.snapshot.progress, closeTo(0.95 * 0.3, 1e-9));

    transport.ack(transport.held.single);
    await pumpEventQueue();
    expect(job.snapshot.item('v')!.progress, 1);
    expect(job.snapshot.state, const PublishJobState.awaitingPublisher());
    expect(job.snapshot.progress, closeTo(0.95, 1e-9));

    h.transfers.registerPublisher(publisherId, publisher);
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.publishing());
    expect(job.snapshot.progress, closeTo(0.95, 1e-9));

    publisher.answer();
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.completed(null));
    expect(job.snapshot.progress, 1);
  });

  test('a photo preparation weighs 2 % of its item', () async {
    final preparation = FakeMediaPreparation();
    final h = await publishing([fakeTransport()], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'p',
          PublishSource.prepare(inputOf(1000), const PreparationIntent.photo()),
        ),
      ]),
    );
    await pumpEventQueue();
    preparation.last.report(0.5);
    await pumpEventQueue();
    expect(job.snapshot.item('p')!.progress, closeTo(0.01, 1e-9));
  });

  test('the weights are the facade\'s to set', () async {
    final preparation = FakeMediaPreparation();
    final h = await publishing(
      [fakeTransport()],
      preparation: preparation,
      progressWeights: const PublishProgressWeights(
        videoPreparation: 0.5,
        publish: 0.2,
      ),
    );
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(inputOf(1000), const PreparationIntent.video()),
        ),
      ]),
    );
    await pumpEventQueue();
    preparation.last.report(0.5);
    await pumpEventQueue();
    expect(job.snapshot.item('v')!.progress, closeTo(0.25, 1e-9));
    expect(job.snapshot.progress, closeTo(0.8 * 0.25, 1e-9));
  });

  test('items weigh their bytes: a big file moves the job more than a small '
      'one', () async {
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport]);
    final job = h.transfers.publish(
      requestOf([
        itemOf('small', PublishSource.prepared(preparedOf(100))),
        itemOf('big', PublishSource.prepared(preparedOf(300))),
      ]),
    );
    await pumpEventQueue();
    // Each file is one part; the first held one finishes first.
    transport.ack(transport.held.first);
    await pumpEventQueue();
    final done = [
      for (final item in job.snapshot.items)
        if (item.progress == 1) item.itemId,
    ];
    expect(done, hasLength(1));
    final weight = done.single == 'small' ? 100 : 300;
    expect(job.snapshot.progress, closeTo(0.95 * weight / 400, 1e-9));
  });

  test('a remote item and a reuse hit count as done at once', () async {
    final h = await publishing([fakeTransport()]);
    final file = preparedOf(50);
    h.transfers.upload(
      itemOf('first', PublishSource.prepared(file), fingerprint: 'f-1'),
    );
    await pumpEventQueue();

    final job = h.transfers.publish(
      requestOf([
        itemOf('again', PublishSource.prepared(file), fingerprint: 'f-1'),
        itemOf('r', const PublishSource.remote()),
      ]),
    );
    await pumpEventQueue();
    expect(job.snapshot.item('again')!.progress, 1);
    expect(job.snapshot.item('r')!.progress, 1);
    expect(job.snapshot.state, const PublishJobState.awaitingPublisher());
    expect(job.snapshot.progress, closeTo(0.95, 1e-9));
  });

  test('a job with no items is at 95 % until its publisher answers', () async {
    final h = await publishing([]);
    final job = h.transfers.publish(requestOf(const []));
    await pumpEventQueue();
    expect(job.snapshot.progress, closeTo(0.95, 1e-9));
    h.transfers.registerPublisher(publisherId, FakePublisher());
    await pumpEventQueue();
    expect(job.snapshot.progress, 1);
  });

  test('a prepared size larger than the source never lowers the job, and '
      'the job still ends at 1', () async {
    final preparation = FakeMediaPreparation();
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport], preparation: preparation);
    final input = inputOf(100);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(input, const PreparationIntent.video()),
        ),
        itemOf('f', PublishSource.prepared(preparedOf(100))),
      ]),
    );
    final seen = <double>[];
    job.watch().listen((snapshot) => seen.add(snapshot.progress));
    await pumpEventQueue();
    transport.ack(transport.held.single);
    preparation.last.report(0.9);
    await pumpEventQueue();
    final before = job.snapshot.progress;
    expect(before, closeTo(0.95 * (0.27 + 1) / 2, 1e-9));

    // Ten times the source: by bytes alone the job would drop below half.
    sourceFiles.put('${input.path}.big', size: 1000);
    preparation.last.complete(
      PreparedMedia(
        kind: PreparedKind.video,
        path: '${input.path}.big',
        isOriginal: false,
        byteSize: 1000,
      ),
    );
    await pumpEventQueue();
    expect(job.snapshot.progress, greaterThanOrEqualTo(before));

    transport.ack(transport.held.single);
    await pumpEventQueue();
    h.transfers.registerPublisher(publisherId, FakePublisher());
    await pumpEventQueue();
    expect(job.snapshot.progress, 1);
    expect(seen, orderedEquals([...seen]..sort()));
  });

  test('a restart keeps the progress the job had reached', () async {
    final preparation = FakeMediaPreparation();
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport], preparation: preparation);
    final input = inputOf(100);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(input, const PreparationIntent.video()),
        ),
        itemOf('f', PublishSource.prepared(preparedOf(100))),
      ]),
    );
    await pumpEventQueue();
    transport.ack(transport.held.single);
    preparation.last.report(0.9);
    await pumpEventQueue();
    sourceFiles.put('${input.path}.big', size: 1000);
    preparation.last.complete(
      PreparedMedia(
        kind: PreparedKind.video,
        path: '${input.path}.big',
        isOriginal: false,
        byteSize: 1000,
      ),
    );
    await pumpEventQueue();
    final before = job.snapshot.progress;
    await h.settle();

    final transfers = await h.kill();
    await pumpEventQueue();
    final after = transfers.publishJob(job.id)!.snapshot.progress;
    expect(after, greaterThanOrEqualTo(before));
  });

  test('a cell reads its item\'s progress from watchItem', () async {
    final preparation = FakeMediaPreparation();
    final h = await publishing([fakeTransport()], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(inputOf(1000), const PreparationIntent.video()),
        ),
      ]),
    );
    final seen = <double>[];
    job.watchItem('v').listen((item) => seen.add(item.progress));
    await pumpEventQueue();
    preparation.last.report(0.5);
    await pumpEventQueue();
    preparation.last.complete();
    await pumpEventQueue();
    expect(seen.first, 0);
    expect(seen, contains(closeTo(0.15, 1e-9)));
    expect(seen.last, 1);
  });

  test('progress moving reports nothing at debug or above', () async {
    final preparation = FakeMediaPreparation();
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepare(inputOf(1000), const PreparationIntent.video()),
        ),
        itemOf('f', PublishSource.prepared(preparedOf(4 * part))),
      ]),
    );
    job.watch().listen((_) {});
    await pumpEventQueue();
    transport.ack(transport.held.first);
    await pumpEventQueue();

    final recorder = RecordingDiagnostics.install();
    for (var step = 0; step < 4; step++) {
      preparation.last.report(0.2 * (step + 1));
      await pumpEventQueue();
    }
    transport.ack(transport.held.first);
    await pumpEventQueue();
    transport.ack(transport.held.first);
    await pumpEventQueue();

    expect(job.snapshot.progress, greaterThan(0));
    expect([
      for (final event in recorder.events)
        if (event.level.index >= MpxEventLevel.debug.index) event,
    ], isEmpty);
    for (final event in recorder.events) {
      expect(event.fields.keys, isNot(contains('progress')));
    }
  });

  group('over random item mixes and event orders', () {
    for (var seed = 0; seed < 24; seed++) {
      test('progress never goes back and ends at 1 (seed $seed)', () async {
        await _randomRun(Random(seed));
      });
    }
  });
}

Future<void> _randomRun(Random random) async {
  final preparation = FakeMediaPreparation();
  final transport = fakeTransport(holdParts: true);
  final publisher = FakePublisher();
  final h = await publishing([transport], preparation: preparation);
  final items = [
    for (var i = 0; i < 1 + random.nextInt(4); i++)
      itemOf('i$i', switch (random.nextInt(4)) {
        0 => PublishSource.prepare(
          inputOf(1 + random.nextInt(3 * part)),
          const PreparationIntent.video(),
        ),
        1 => PublishSource.prepare(
          inputOf(1 + random.nextInt(3 * part)),
          const PreparationIntent.photo(),
        ),
        2 => PublishSource.prepared(preparedOf(1 + random.nextInt(3 * part))),
        _ => const PublishSource.remote(),
      }),
  ];
  final early = random.nextBool();
  if (early) h.transfers.registerPublisher(publisherId, publisher);
  final job = h.transfers.publish(requestOf(items));
  final jobSeen = <double>[];
  final itemSeen = <String, List<double>>{};
  job.watch().listen((snapshot) {
    jobSeen.add(snapshot.progress);
    for (final item in snapshot.items) {
      itemSeen.putIfAbsent(item.itemId, () => []).add(item.progress);
    }
  });
  await pumpEventQueue();

  for (var step = 0; step < 400; step++) {
    if (job.snapshot.state is PublishJobState$Completed) break;
    final pending = preparation.pending;
    final held = transport.held;
    final moves = <void Function()>[
      for (final handle in pending) ...[
        () => handle.report(handle.progress.value + random.nextDouble() / 2),
        () {
          // A prepared size that may be far from the source's.
          final path = '${handle.input.path}.out$step';
          final size = 1 + random.nextInt(3 * part);
          sourceFiles.put(path, size: size);
          handle.complete(
            PreparedMedia(
              kind: handle.intent is PreparationIntent$Video
                  ? PreparedKind.video
                  : PreparedKind.photo,
              path: path,
              isOriginal: false,
              byteSize: size,
            ),
          );
        },
      ],
      for (final index in held) () => transport.ack(index),
    ];
    if (moves.isEmpty) {
      if (!early) h.transfers.registerPublisher(publisherId, publisher);
      await pumpEventQueue();
      continue;
    }
    moves[random.nextInt(moves.length)]();
    await pumpEventQueue();
  }

  expect(job.snapshot.state, const PublishJobState.completed(null));
  expect(job.snapshot.progress, 1);
  expect(jobSeen.last, 1);
  _expectRising(jobSeen);
  for (final seen in itemSeen.values) {
    _expectRising(seen);
    expect(seen.last, 1);
  }
}

void _expectRising(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    expect(
      values[i],
      greaterThanOrEqualTo(values[i - 1]),
      reason: 'progress went back at $i of $values',
    );
    expect(values[i], inInclusiveRange(0, 1));
  }
}
