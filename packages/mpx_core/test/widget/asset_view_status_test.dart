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

  Widget host(Widget child, {AssetViewSkin? skin}) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: AssetCacheProvider(
      scope: scope,
      child: MediaLoadingStyleScope(
        skin: skin,
        child: Center(child: child),
      ),
    ),
  );

  testWidgets('a manual photo: preview, download and its size; a tap '
      'downloads, the arc grows and the photo arrives', (tester) async {
    await tester.pumpWidget(
      host(
        const AssetView(
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

  testWidgets('the badge sits inside the picture a contain fit letterboxes, '
      'at the style offset from its corner', (tester) async {
    const square = AssetPreset(
      size: Size(160, 160),
      spec: AssetSpec(pixelWidth: 160, pixelHeight: 160),
      profile: AssetProfile(cornerRadius: 12),
    );
    await tester.pumpWidget(
      host(const AssetView(content: _key, preset: square, badge: true)),
    );
    // A 2:1 picture: drawn 160 x 80 from y = 40 of the square box.
    producer.last
      ..describe(
        const MediaDescriptor(
          key: _key,
          kind: MediaKind.video,
          byteSize: 4718592,
          duration: Duration(seconds: 20),
          dimensions: MediaDimensions(320, 160),
        ),
      )
      ..awaitingUser();
    await tester.pump();
    await tester.pump(_gone);

    final box = tester.getTopLeft(find.byType(AssetView));
    final badge = tester.getTopLeft(find.byType(MediaBadge));
    // Android's offset is 4 x 4.
    expect(badge - box, const Offset(4, 44));
  });

  testWidgets('the badge of a cover fit sits at the corner of the box, the '
      'picture it shows filling it', (tester) async {
    const square = AssetPreset(
      size: Size(160, 160),
      spec: AssetSpec(pixelWidth: 160, pixelHeight: 160),
      profile: AssetProfile(cornerRadius: 12, fit: AssetFit.cover),
    );
    await tester.pumpWidget(
      host(const AssetView(content: _key, preset: square, badge: true)),
    );
    // A 1:2 picture, cut top and bottom to fill the square.
    producer.last
      ..describe(
        const MediaDescriptor(
          key: _key,
          kind: MediaKind.video,
          byteSize: 4718592,
          duration: Duration(seconds: 20),
          dimensions: MediaDimensions(160, 320),
        ),
      )
      ..awaitingUser();
    await tester.pump();
    await tester.pump(_gone);

    final box = tester.getTopLeft(find.byType(AssetView));
    final badge = tester.getTopLeft(find.byType(MediaBadge));
    expect(badge - box, const Offset(4, 4));
  });

  testWidgets('the compact control sits inside the picture a contain fit '
      'letterboxes', (tester) async {
    const square = AssetPreset(
      size: Size(160, 160),
      spec: AssetSpec(pixelWidth: 160, pixelHeight: 160),
      profile: AssetProfile(),
    );
    await tester.pumpWidget(
      host(
        const AssetView(
          content: _key,
          preset: square,
          status: MediaStatusMode.compact,
        ),
      ),
    );
    // A 1:2 picture: drawn 80 x 160 from x = 40 of the square box.
    producer.last
      ..describe(
        const MediaDescriptor(
          key: _key,
          kind: MediaKind.still,
          byteSize: 4718592,
          dimensions: MediaDimensions(160, 320),
        ),
      )
      ..awaitingUser();
    await tester.pump();
    await tester.pump(_gone);

    final box = tester.getTopLeft(find.byType(AssetView));
    final control = tester.getTopLeft(find.byType(MediaStatusControl));
    // Android's compact control is at 8 x 8.
    expect(control - box, const Offset(48, 8));
  });

  testWidgets('a failure turns the control back to download', (tester) async {
    await tester.pumpWidget(
      host(
        const AssetView(
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
        AssetView(
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
      'and the thumbnail, which paint beneath it (a clear placeholder never '
      'leaves the view black)', (tester) async {
    final own = FakeAssetPaintable(label: 'origin');
    await tester.pumpWidget(
      host(
        AssetView(
          content: _key,
          preset: _preset,
          placeholder: own,
          placeholderUntil: AssetStage.firstFrame,
        ),
      ),
    );
    final preview = producer.last.advance(AssetStage.preview);
    await tester.pump();
    expect(preview.paints, isNotEmpty);
    final thumbnail = producer.last.advance(AssetStage.placeholder);
    await tester.pump();
    await tester.pump(_gone);

    expect(thumbnail.paints, isNotEmpty);
    expect(own.paints, isNotEmpty);

    final content = producer.last.advance(AssetStage.full);
    await tester.pump();
    await tester.pump(_gone);
    expect(content.paints, isNotEmpty);
  });

  testWidgets('content rising over an outranking placeholder fades in over '
      'it and the thumbnail beneath, both opaque: no dip, no gap', (
    tester,
  ) async {
    final own = FakeAssetPaintable(label: 'origin');
    await tester.pumpWidget(
      host(
        AssetView(
          content: _key,
          preset: _preset,
          placeholder: own,
          placeholderUntil: AssetStage.firstFrame,
        ),
      ),
    );
    final thumbnail = producer.last.advance(AssetStage.placeholder);
    await tester.pump();
    await tester.pump(_gone);

    final content = producer.last.advance(AssetStage.full);
    await tester.pump();
    // Half way through the 150 ms rise.
    await tester.pump(const Duration(milliseconds: 75));
    final rising = content.paints.last.context.opacity;
    expect(rising, greaterThan(0));
    expect(rising, lessThan(1));
    expect(own.paints.last.context.opacity, 1);
    expect(thumbnail.paints.last.context.opacity, 1);
  });

  testWidgets("a skin's status gets the headless state and the stock "
      'control; it follows the download, the picture is not rebuilt', (
    tester,
  ) async {
    final states = <AssetLoadState>[];
    await tester.pumpWidget(
      host(
        const AssetView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.control(),
        ),
        skin: AssetViewSkin(
          status: (context, state, stock) {
            states.add(state);
            expect(stock, isA<MediaStatusControl>());
            return Text('host ${state.fraction ?? '-'}');
          },
        ),
      ),
    );
    expect(find.byType(MediaStatusControl), findsNothing);
    producer.last.transfer(30, 100);
    await tester.pump();
    expect(find.text('host 0.3'), findsOneWidget);
    expect(states.last.loading, isTrue);
    expect(states.last.transfer, const AssetTransfer.receiving(30, 100));
  });

  testWidgets("the view's own skin wins over the scope's, part by part", (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AssetView(
          content: _key,
          preset: _preset,
          status: MediaStatusMode.compact,
          badge: true,
          skin: AssetViewSkin(
            status: (context, state, stock) =>
                Text('mine ${(stock as MediaStatusControl).compact}'),
          ),
        ),
        skin: AssetViewSkin(
          status: (context, state, stock) => const Text('scope'),
          badge: (context, state, stock) => const Text('scope badge'),
        ),
      ),
    );

    expect(find.text('mine true'), findsOneWidget);
    expect(find.text('scope'), findsNothing);
    expect(find.text('scope badge'), findsOneWidget);
  });

  testWidgets("a skin's reveal wraps the picture with its state, and keeps "
      'it in place as the stage rises', (tester) async {
    final shown = <bool>[];
    await tester.pumpWidget(
      host(
        AssetView(
          content: _key,
          preset: _preset,
          skin: AssetViewSkin(
            reveal: (context, state, picture) {
              shown.add(state.shown);
              return Opacity(
                key: const ValueKey('reveal'),
                opacity: state.shown ? 1 : 0,
                child: picture,
              );
            },
          ),
        ),
      ),
    );
    double opacity() =>
        tester.widget<Opacity>(find.byKey(const ValueKey('reveal'))).opacity;
    expect(opacity(), 0);
    Element picture() {
      late Element child;
      tester
          .element(find.byKey(const ValueKey('reveal')))
          .visitChildren((e) => child = e);
      return child;
    }

    final before = picture();
    producer.last.advance(AssetStage.full);
    await tester.pump();
    expect(opacity(), 1);
    expect(shown.last, isTrue);
    expect(identical(picture(), before), isTrue);
  });

  testWidgets('AssetLoadStateBuilder: a host UI from the same entry, with '
      'no view of its own', (tester) async {
    await tester.pumpWidget(
      host(
        AssetLoadStateBuilder(
          content: _key,
          preset: _preset,
          builder: (context, state, _) =>
              Text('${state.stage.name} ${state.loading} ${state.fraction}'),
        ),
      ),
    );
    producer.last.transfer(50, 200);
    await tester.pump();
    expect(find.text('none true 0.25'), findsOneWidget);
    producer.last.advance(AssetStage.full);
    await tester.pump();
    expect(find.textContaining('full'), findsOneWidget);
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
        const AssetView(
          content: _key,
          preset: tile,
          status: MediaStatusMode.control(),
        ),
      ),
    );
    producer.last.transfer(10, 100);
    await tester.pump(_gone);

    final control = find.byType(MediaStatusControl);
    expect(tester.getSize(find.byType(AssetView)), const Size(300, 300));
    expect(tester.getSize(control), const Size(44, 44));
    expect(tester.getCenter(control), tester.getCenter(find.byType(AssetView)));
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
      AssetView(
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
        const AssetView(content: _key, preset: _preset, requestsDownload: true),
      ),
    );

    expect(producer.last.demand.autoDownload(_clip), AutoDownload.now);
  });
}
