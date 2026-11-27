import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_publish_open_');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<Transfers> open(
    FakeUploadTransport transport, {
    MediaPreparation? preparation,
  }) => Transfers.open(
    cacheKeyOf: (key) => key.encoded,
    lifecycle: ManualPlaybackLifecycleSource(),
    directory: directory.path,
    transports: [transport],
    preparation: preparation,
  );

  test('Transfers.open runs publish jobs through its transports and keeps '
      'them beside the journal, across a restart', () async {
    final file = File('${directory.path}/photo.jpg')
      ..writeAsBytesSync(List.filled(64, 7));
    final transport = FakeUploadTransport(holdParts: true);
    var transfers = await open(transport);
    final job = transfers.publish(
      PublishRequest(
        items: [
          PublishItem(
            itemId: 'a',
            key: MediaKey.local('00000000-0000-4000-8000-0000000000aa'),
            source: PublishSource.prepared(
              PreparedMedia(
                kind: PreparedKind.photo,
                path: file.path,
                isOriginal: true,
                byteSize: 64,
              ),
            ),
          ),
        ],
        payload: Uint8List.fromList([1]),
        publisher: 'p',
      ),
    );
    await pumpEventQueue();
    expect(transport.opens, hasLength(1));
    await transfers.dispose();
    expect(
      File('${directory.path}/mpx_transfer/publish.snapshot').existsSync(),
      isTrue,
    );

    transport.holdParts = false;
    transfers = await open(transport);
    addTearDown(transfers.dispose);
    final publisher = FakePublisher();
    transfers.registerPublisher('p', publisher);
    await pumpEventQueue();
    final back = transfers.publishJob(job.id)!;
    expect(back.snapshot.state, const PublishJobState.completed(null));
    expect(publisher.calls.single.items['a']!.file, isNotNull);
  });

  test(
    'a facade opened without preparation refuses items that need it',
    () async {
      final transfers = await open(FakeUploadTransport());
      addTearDown(transfers.dispose);
      expect(
        () => transfers.publish(
          PublishRequest(
            items: [
              PublishItem(
                itemId: 'a',
                key: MediaKey.local('00000000-0000-4000-8000-0000000000ab'),
                source: const PublishSource.prepare(
                  PreparationInput('/nowhere'),
                  PreparationIntent.photo(),
                ),
              ),
            ],
            payload: Uint8List(0),
            publisher: 'p',
          ),
        ),
        throwsA(isA<PreparationUnavailable>()),
      );
    },
  );
}
