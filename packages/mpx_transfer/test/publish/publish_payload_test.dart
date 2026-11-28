import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_publish_payload_');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<Transfers> open() => Transfers.open(
    cache: TransferBytesCache(keyOf: (key) => key.encoded),
    lifecycle: ManualPlaybackLifecycleSource(),
    directory: directory.path,
    transports: const [],
  );

  // Every byte value, so a text round trip would show.
  final bytes = Uint8List.fromList(List.generate(256, (i) => i));

  Future<Transfers> restart(Transfers transfers) async {
    await transfers.dispose();
    return open();
  }

  Future<List<int>> watched(Transfers transfers, PublishJobId id) async {
    final jobs = await transfers.watchJobs(const PublishJobFilter()).first;
    return jobs.singleWhere((job) => job.id == id).payload;
  }

  test('an owner reads the payload of a job after a restart, from the job '
      'and from watchJobs, through setPayload and commit', () async {
    var transfers = await open();
    final job = transfers.publish(
      PublishRequest(
        items: const [],
        payload: bytes,
        publisher: 'p',
        hold: true,
      ),
    );
    expect(job.payload, bytes);

    transfers = await restart(transfers);
    expect(transfers.publishJob(job.id)!.payload, bytes);
    expect(await watched(transfers, job.id), bytes);

    final replaced = Uint8List.fromList([9, 8, 7, 0, 255]);
    expect(transfers.publishJob(job.id)!.setPayload(replaced), isTrue);
    expect(transfers.publishJob(job.id)!.payload, replaced);
    transfers = await restart(transfers);
    expect(transfers.publishJob(job.id)!.payload, replaced);
    expect(await watched(transfers, job.id), replaced);

    final committed = Uint8List.fromList([0, 1, 2, 254]);
    expect(transfers.publishJob(job.id)!.commit(payload: committed), isTrue);
    transfers = await restart(transfers);
    addTearDown(transfers.dispose);
    expect(transfers.publishJob(job.id)!.payload, committed);
    expect(await watched(transfers, job.id), committed);
  });

  test(
    'the payload is in no diagnostics event nor in the snapshot text',
    () async {
      final recorder = RecordingDiagnostics.install();
      final transfers = await open();
      addTearDown(transfers.dispose);
      final marker = Uint8List.fromList('payload-marker'.codeUnits);
      final job = transfers.publish(
        PublishRequest(items: const [], payload: marker, publisher: 'p'),
      );
      job.setPayload(marker);
      await pumpEventQueue();
      for (final event in recorder.events) {
        final text = '${event.fields} ${event.tag}';
        expect(text, isNot(contains('payload-marker')));
        expect(text, isNot(contains(marker.join(','))));
        expect(text, isNot(contains(String.fromCharCodes(marker))));
      }
      expect(job.snapshot.toString(), isNot(contains('payload-marker')));
    },
  );
}
