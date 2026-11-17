import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _key = MediaKey.remote('photo');
const _preset = AssetPreset(
  size: Size(200, 150),
  spec: AssetSpec(pixelWidth: 200, pixelHeight: 150),
  profile: AssetProfile(),
);
const _photo = MediaDescriptor(
  key: _key,
  kind: MediaKind.still,
  byteSize: 4718592,
);
const _clip = MediaDescriptor(
  key: _key,
  kind: MediaKind.video,
  byteSize: 4718592,
  duration: Duration(seconds: 13),
  streamable: true,
);
const _gone = Duration(milliseconds: 400);

void main() {
  late FakeAssetProducer producer;
  late AssetCacheScope scope;

  setUp(() {
    producer = FakeAssetProducer();
    scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
    addTearDown(scope.dispose);
  });

  Widget host(Widget child, {MediaStatusBuilder? statusBuilder}) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: AssetCacheProvider(
      scope: scope,
      child: MediaLoadingStyleScope(
        statusBuilder: statusBuilder,
        child: Center(child: child),
      ),
    ),
  );

  testWidgets('a manual photo: preview, download and its size; a tap '
      'downloads, the arc grows and the photo arrives', (tester) async {
    await tester.pumpWidget(
      host(
        const ContentView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.control(),
          badge: true,
        ),
      ),
    );
    producer.last
      ..describe(_photo)
      ..advance(AssetStage.preview)
      ..awaitingUser();
    await tester.pump(_gone);

    expect(find.bySemanticsLabel('Download'), findsOneWidget);
    expect(find.text('4.5 MB'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Download'));
    expect(producer.attempts, hasLength(2));
    producer.last.transfer(2306867, null);
    await tester.pump(_gone);
    expect(find.bySemanticsLabel('Cancel download'), findsOneWidget);
    expect(find.text('2.2 MB / 4.5 MB'), findsOneWidget);

    producer.last.advance(AssetStage.full);
    await tester.pump();
    await tester.pump(_gone);
    expect(find.bySemanticsLabel('Cancel download'), findsNothing);
    expect(find.text('4.5 MB'), findsNothing);
  });

  testWidgets('a failure turns the control back to download', (tester) async {
    await tester.pumpWidget(
      host(
        const ContentView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.control(),
        ),
      ),
    );
    producer.last.transfer(10, 100);
    await tester.pump(_gone);
    expect(find.bySemanticsLabel('Cancel download'), findsOneWidget);

    producer.last.fail(StateError('offline'));
    await tester.pump(_gone);

    expect(find.bySemanticsLabel('Download'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Download'));
    expect(producer.attempts, hasLength(2));
  });

  testWidgets('streamable video not local: play in the centre and a compact '
      'download with the size', (tester) async {
    var plays = 0;
    await tester.pumpWidget(
      host(
        ContentView(
          content: _key,
          preset: _preset,
          status: const MediaStatusMode.control(),
          badge: true,
          onPlay: () => plays++,
        ),
      ),
    );
    producer.last
      ..describe(_clip)
      ..awaitingUser();
    await tester.pump(_gone);

    expect(find.byType(MediaStatusControl), findsNWidgets(2));
    final compact = tester.widget<MediaStatusControl>(
      find.byWidgetPredicate(
        (widget) => widget is MediaStatusControl && widget.compact,
      ),
    );
    expect(compact.binding, isNotNull);
    expect(tester.getSize(find.byWidget(compact)), const Size(24, 24));
    expect(find.text('0:13'), findsOneWidget);
    expect(find.text('4.5 MB'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Play'));
    expect(plays, 1);
    await tester.tap(find.bySemanticsLabel('Download'));
    expect(producer.attempts, hasLength(2));
  });

  testWidgets('placeholderUntil keeps the view placeholder over the preview '
      'and the thumbnail', (tester) async {
    final own = FakeAssetPaintable(label: 'origin');
    await tester.pumpWidget(
      host(
        ContentView(
          content: _key,
          preset: _preset,
          placeholder: own,
          placeholderUntil: AssetStage.firstFrame,
        ),
      ),
    );
    final preview = producer.last.advance(AssetStage.preview);
    await tester.pump();
    final thumbnail = producer.last.advance(AssetStage.placeholder);
    await tester.pump();

    expect(preview.paints, isEmpty);
    expect(thumbnail.paints, isEmpty);
    expect(own.paints, isNotEmpty);

    final content = producer.last.advance(AssetStage.full);
    await tester.pump();
    await tester.pump(_gone);
    expect(content.paints, isNotEmpty);
  });

  testWidgets('a host builder replaces the control; byte reports do not '
      'rebuild the view', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      host(
        const ContentView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.control(),
        ),
        statusBuilder: (context, control) {
          builds++;
          return const Text('host control');
        },
      ),
    );
    expect(find.text('host control'), findsOneWidget);
    expect(find.byType(MediaStatusControl), findsNothing);
    final before = builds;

    producer.last
      ..transfer(10, 100)
      ..transfer(20, 100);
    await tester.pump();
    producer.last.transfer(30, 100);
    await tester.pump();

    expect(builds, before);
  });

  testWidgets("the view's own builder wins over the scope's", (tester) async {
    await tester.pumpWidget(
      host(
        ContentView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.compact,
          statusBuilder: (context, control) => Text('mine ${control.compact}'),
        ),
        statusBuilder: (context, control) => const Text('scope'),
      ),
    );

    expect(find.text('mine true'), findsOneWidget);
  });

  testWidgets('the control keeps its style size over a large tile', (
    tester,
  ) async {
    const tile = AssetPreset(
      size: Size(300, 300),
      spec: AssetSpec(pixelWidth: 300, pixelHeight: 300),
      profile: AssetProfile(),
    );
    await tester.pumpWidget(
      host(
        const ContentView(
          content: _key,
          preset: tile,
          status: MediaStatusMode.control(),
        ),
      ),
    );
    producer.last.transfer(10, 100);
    await tester.pump(_gone);

    final control = find.byType(MediaStatusControl);
    expect(tester.getSize(find.byType(ContentView)), const Size(300, 300));
    expect(tester.getSize(control), const Size(44, 44));
    expect(
      tester.getCenter(control),
      tester.getCenter(find.byType(ContentView)),
    );
  });

  testWidgets('a control alone in tight constraints keeps its size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const SizedBox(
          width: 300,
          height: 300,
          child: MediaStatusControl(
            status: MediaStatus.icon(MediaStatusIcon.download),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(CustomPaint).last), const Size(44, 44));
  });

  testWidgets('rebinding a tile mid-download paints the current fraction on '
      'its first frame', (tester) async {
    Widget tile() => host(
      ContentView(
        key: UniqueKey(),
        content: _key,
        preset: _preset,
        status: const MediaStatusMode.control(),
      ),
    );
    await tester.pumpWidget(tile());
    producer.last.transfer(50, 100);
    await tester.pump(_gone);
    // The tile leaves the screen; its attempt is cancelled.
    await tester.pumpWidget(host(const SizedBox()));

    // The next attempt starts again from what its request reports.
    producer.onProduce = (attempt) => attempt
      ..waiting()
      ..transfer(5, 100);
    await tester.pumpWidget(tile());

    expect(
      find.byType(MediaStatusControl),
      paints
        ..circle()
        ..arc(sweepAngle: math.pi),
    );
  });

  testWidgets('a view that is the user request downloads whatever the policy '
      'says', (tester) async {
    scope.dispose();
    scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      autoDownload: FakeAutoDownloadPolicy(),
    );
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      host(
        const ContentView(
          content: _key,
          preset: _preset,
          requestsDownload: true,
        ),
      ),
    );

    expect(producer.last.demand.autoDownload(_clip), AutoDownload.now);
  });
}
