import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import '../support.dart';
import 'download_support.dart';

void main() {
  testWidgets('an AssetView in a scope wired with tracked downloads shows the '
      'job receiving, then the picture', (tester) async {
    final h = await DownloadsHarness.open();
    final decoder = FakeDecoder();
    final pipeline = AssetPipeline(
      fetcher: h.fetcher,
      decoders: DecoderRegistry()..register(MediaKind.still, decoder),
    )..know(photoItem);
    final scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      tracked: h.tracked,
    );
    addTearDown(() {
      scope.dispose();
      pipeline.dispose();
    });
    const spec = AssetSpec(pixelWidth: 64, pixelHeight: 64);

    await tester.pumpWidget(
      MaterialApp(
        home: AssetCacheProvider(
          scope: scope,
          child: const Center(
            child: AssetView(
              content: photo,
              preset: AssetPreset(
                size: Size(100, 100),
                spec: spec,
                profile: AssetProfile(),
              ),
              status: MediaStatusMode.control(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await h.fetcher.step();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.valueOf(photo), const AssetTransfer.receiving(100, 400));
    expect(find.bySemanticsLabel('Cancel download'), findsOneWidget);
    expect(h.fetcher.contentRequests, hasLength(1));
    bool decodedContent() => decoder.decodes.any(
      (decode) => decode.request.part == FetchPart.content,
    );
    expect(decodedContent(), isFalse);

    for (var i = 0; i < 3; i++) {
      await h.fetcher.step();
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.valueOf(photo), AssetTransfer.none);
    expect(decodedContent(), isTrue);
    expect(find.bySemanticsLabel('Cancel download'), findsNothing);
    expect(find.bySemanticsLabel('Download'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await h.transfers.dispose();
  });
}
