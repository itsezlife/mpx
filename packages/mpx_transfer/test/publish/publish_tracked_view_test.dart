import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show BytesCacheKey;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';
import 'tracked_support.dart';

void main() {
  testWidgets('an AssetView of an upload\'s local content shows the upload '
      'ring, forwards its cancel and keeps the picture', (tester) async {
    final recorder = RecordingDiagnostics.install();
    final h = await TrackedHarness.open();
    final key = keyOf('v1');
    final descriptor = MediaDescriptor(
      key: key,
      kind: MediaKind.still,
      byteSize: 3,
    );
    final decoder = FakeDecoder();
    final pipeline = AssetPipeline(
      fetcher: h.fetcher,
      decoders: DecoderRegistry()..register(MediaKind.still, decoder),
    )..know(descriptor);
    final scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      tracked: h.tracked,
    );
    addTearDown(() {
      scope.dispose();
      pipeline.dispose();
    });
    await h.store.store.write(
      BytesCacheKey(key.encoded),
      Uint8List.fromList(const [1, 2, 3]),
    );
    final job = h.transfers.publish(
      requestOf([
        for (final id in ['v1', 'v2'])
          itemOf(id, PublishSource.prepared(preparedOf(3 * part))),
      ]),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: AssetCacheProvider(
          scope: scope,
          child: Center(
            child: AssetView(
              content: key,
              preset: const AssetPreset(
                size: Size(100, 100),
                spec: AssetSpec(pixelWidth: 64, pixelHeight: 64),
                profile: AssetProfile(),
              ),
              status: const MediaStatusMode.control(),
            ),
          ),
        ),
      ),
    );
    h.transport.held.forEach(h.transport.ack);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.valueOf(key), isA<AssetTransfer$Sending>());
    expect(find.bySemanticsLabel('Cancel upload'), findsOneWidget);
    final decoded = decoder.decodes.length;
    expect(decoded, greaterThan(0));

    await tester.tap(find.bySemanticsLabel('Cancel upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      recorder.whereOp(BindingOp.cancelForwarded).single,
      isMpxEvent(
        level: MpxEventLevel.info,
        mediaKey: key,
        fields: {'direction': 'upload'},
      ),
    );
    expect(
      recorder.whereOp(PublishOp.itemRemoved).single,
      isMpxEvent(itemId: 'v1', fields: {'by': 'cell'}),
    );
    expect(job.snapshot.items.map((item) => item.itemId), ['v2']);
    expect(find.bySemanticsLabel('Cancel upload'), findsNothing);
    expect(find.bySemanticsLabel('Download'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await h.transfers.dispose();
  });
}
