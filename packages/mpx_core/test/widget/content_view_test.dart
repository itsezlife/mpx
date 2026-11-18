import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _sticker = MediaKey.remote('42');
const _other = MediaKey.remote('43');
// A small playing cell and its still twin.
final _preset = AssetPresets.square(
  extent: 20,
  devicePixelRatio: 2,
  profile: const AssetProfile(animate: true, halfFrameRate: true),
);
final _still = AssetPresets.square(
  extent: 20,
  devicePixelRatio: 2,
  profile: const AssetProfile(),
);
// Long enough for content that arrived after the attach to have faded in,
// a playing view's too (250 ms).
const _pastFade = Duration(milliseconds: 260);

// Longer than any platform's control takes to go.
const _controlGone = Duration(milliseconds: 400);

void main() {
  late FakeAssetProducer producer;
  late ManualPlaybackTickSource ticks;
  late AssetCacheScope scope;

  setUp(() {
    producer = FakeAssetProducer();
    ticks = ManualPlaybackTickSource();
    scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ticks),
    );
    addTearDown(scope.dispose);
  });

  Widget host(Widget child, {AssetCacheScope? provided}) => Directionality(
    textDirection: TextDirection.ltr,
    child: AssetCacheProvider(
      scope: provided ?? scope,
      child: Center(child: child),
    ),
  );

  group('frame', () {
    // A 40 px rounded square that shows a 4:3 picture whole.
    const size = Size(40, 40);
    final rounded = AssetPreset(
      size: size,
      spec: AssetSpec.atDensity(
        logicalWidth: size.width,
        logicalHeight: size.height,
        devicePixelRatio: 1,
      ),
      profile: const AssetProfile(cornerRadius: 8),
    );

    Future<RenderObject> view(WidgetTester tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        host(
          SizedBox.fromSize(
            key: key,
            size: size,
            child: ContentView(content: _sticker, preset: rounded),
          ),
        ),
      );
      return tester.renderObject(find.byKey(key));
    }

    testWidgets('of content is its whole picture, unrounded, at its own '
        'proportion and covering the view', (tester) async {
      final root = await view(tester);
      producer.last.advance(
        AssetStage.full,
        pictureSize: const Size(1200, 900),
        fill: const Color(0xFF0000FF),
      );
      await tester.pump();
      await tester.pump(_pastFade);

      final frame = ContentView.frameIn(root, pixelRatio: 2);
      expect(frame, isA<ContentFrame$Picture>());
      final image = (frame as ContentFrame$Picture).image;
      addTearDown(image.dispose);
      // 4:3 covering 40 x 40 at 2x: 107 x 80.
      expect(image.width, 107);
      expect(image.height, 80);
      final pixels = await tester.runAsync(
        () async => (await image.toByteData())!,
      );
      // The corner the view rounds is drawn.
      expect(pixels!.getUint8(3), 255);
    });

    testWidgets('of a view that shows only a stand-in is none of its own', (
      tester,
    ) async {
      final root = await view(tester);
      expect(
        ContentView.frameIn(root, pixelRatio: 1),
        isA<ContentFrame$StandIn>(),
      );
      producer.last.advance(
        AssetStage.preview,
        pictureSize: const Size(40, 30),
        fill: const Color(0xFF00FF00),
      );
      await tester.pump();
      expect(
        ContentView.frameIn(root, pixelRatio: 1),
        isA<ContentFrame$StandIn>(),
      );
      producer.last.advance(
        AssetStage.placeholder,
        pictureSize: const Size(120, 90),
        fill: const Color(0xFF00FF00),
      );
      await tester.pump();
      await tester.pump(_pastFade);
      expect(
        ContentView.frameIn(root, pixelRatio: 1),
        isA<ContentFrame$StandIn>(),
      );
    });

    testWidgets('of a texture is its frame alone, at its own proportion', (
      tester,
    ) async {
      final root = await view(tester);
      producer.last
          .advance(AssetStage.full, animated: true)
          .texture = const AssetTexture(
        id: 3,
        width: 1280,
        height: 960,
        frameWidth: 1200,
        frameHeight: 900,
      );
      await tester.pump();
      await tester.pump(_pastFade);

      final frame = ContentView.frameIn(root, pixelRatio: 2);
      expect(frame, isA<ContentFrame$Picture>());
      final image = (frame as ContentFrame$Picture).image;
      addTearDown(image.dispose);
      // The 4:3 frame covering 40 x 40 at 2x.
      expect((image.width, image.height), (107, 80));
    });

    testWidgets("of a surface's own picture is its texture, unclipped and "
        'whole', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        host(
          SizedBox.square(
            key: key,
            dimension: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: const ContentPicture(
                child: OverflowBox(
                  maxWidth: 80,
                  maxHeight: 45,
                  child: SizedBox(
                    width: 80,
                    height: 45,
                    child: Texture(textureId: 7),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final frame = ContentView.frameIn(
        tester.renderObject(find.byKey(key)),
        pixelRatio: 2,
      );
      expect(frame, isA<ContentFrame$Picture>());
      final image = (frame as ContentFrame$Picture).image;
      addTearDown(image.dispose);
      expect((image.width, image.height), (160, 90));
    });

    testWidgets("of a surface's own picture with no texture is the surface", (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        host(
          SizedBox.square(
            key: key,
            dimension: 40,
            child: const ContentPicture(
              child: ColoredBox(color: Color(0xFF00FF00)),
            ),
          ),
        ),
      );
      expect(
        ContentView.frameIn(
          tester.renderObject(find.byKey(key)),
          pixelRatio: 1,
        ),
        isA<ContentFrame$Surface>(),
      );
    });

    testWidgets('under no view is read from the surface', (tester) async {
      await tester.pumpWidget(host(const SizedBox.square(dimension: 10)));
      expect(
        ContentView.frameIn(
          tester.renderObject(find.byType(SizedBox)),
          pixelRatio: 1,
        ),
        isA<ContentFrame$Surface>(),
      );
    });
  });

  group('attach', () {
    testWidgets('attaches the content with the preset on first build', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      expect(scope.isAttached(_sticker, _preset.spec), isTrue);
      expect(producer.attempts.single.request.spec, _preset.spec);
    });

    testWidgets('passes its download context to the attach', (tester) async {
      await tester.pumpWidget(
        host(
          ContentView(
            content: _sticker,
            preset: _preset,
            downloadContext: AutoDownloadContext.groups,
          ),
        ),
      );

      expect(producer.last.demand.downloadContexts, {
        AutoDownloadContext.groups,
      });
      expect(scope.entryCount, 1);
    });

    testWidgets('passes its visible fraction to the binding', (tester) async {
      await tester.pumpWidget(
        host(
          ContentView(content: _sticker, preset: _preset, visibleFraction: 0.3),
        ),
      );
      expect(producer.last.demand.priority, AssetPriority.visible);

      await tester.pumpWidget(
        host(
          ContentView(content: _sticker, preset: _preset, visibleFraction: 0),
        ),
      );
      expect(producer.last.demand.priority, AssetPriority.preload);
    });

    testWidgets('a playing view a fade above shows plays within a frame of '
        'showing, and a still screen still measures nothing', (tester) async {
      final opacity = ValueNotifier<double>(0);
      addTearDown(opacity.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<double>(
            valueListenable: opacity,
            builder: (context, value, child) =>
                Opacity(opacity: value, child: child),
            child: ContentView(content: _sticker, preset: _preset),
          ),
        ),
      );
      await tester.pump();
      expect(producer.last.demand.priority, AssetPriority.preload);

      // Nothing moves while it stays transparent.
      ViewportVisibility.debugMeasures = 0;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ViewportVisibility.debugMeasures, 0);

      // The fade starts: shown in the frame it is first painted.
      opacity.value = 0.2;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(producer.last.demand.priority, AssetPriority.visible);

      // On screen and still: no more measuring.
      opacity.value = 1;
      await tester.pump(const Duration(milliseconds: 16));
      ViewportVisibility.debugMeasures = 0;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ViewportVisibility.debugMeasures, 0);
    });

    testWidgets('a playing view on a page that comes back on stage plays '
        'within a frame', (tester) async {
      final offstage = ValueNotifier<bool>(true);
      addTearDown(offstage.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: offstage,
            builder: (context, value, child) =>
                Offstage(offstage: value, child: child),
            child: ContentView(content: _sticker, preset: _preset),
          ),
        ),
      );
      await tester.pump();
      expect(producer.last.demand.priority, AssetPriority.preload);

      offstage.value = false;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(producer.last.demand.priority, AssetPriority.visible);
    });

    testWidgets('a playing view painted outside every viewport is hidden: '
        'only the cells on screen play', (tester) async {
      // A grid laid out whole in a list, as a shrink-wrapped grid is: every
      // cell is built and painted, the ones below the window too.
      tester.view
        ..physicalSize = const Size(200, 200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final keys = [for (var i = 0; i < 30; i++) MediaKey.remote('cell-$i')];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AssetCacheProvider(
            scope: scope,
            child: ListView(
              children: [
                Column(
                  children: [
                    for (final key in keys)
                      ContentView(content: key, preset: _preset),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      // The cells measure where they are after a frame.
      await tester.pump();

      AssetPriority priorityOf(MediaKey key) => producer.attempts
          .lastWhere((a) => a.request.key == key)
          .demand
          .priority;
      expect(priorityOf(keys.first), AssetPriority.visible);
      expect(priorityOf(keys.last), AssetPriority.preload);

      // Scrolled to the end, the last cells play and the first stop.
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
      await tester.pump();
      expect(priorityOf(keys.last), AssetPriority.visible);
      expect(priorityOf(keys.first), AssetPriority.preload);
    });

    testWidgets('views measure where they are only when something moved: '
        'none while nothing does, one pass per frame of a scroll', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(200, 200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final keys = [for (var i = 0; i < 30; i++) MediaKey.remote('cell-$i')];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AssetCacheProvider(
            scope: scope,
            child: ListView(
              children: [
                Column(
                  children: [
                    for (final key in keys)
                      ContentView(content: key, preset: _preset),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Playing frames that move nothing: no measuring.
      ViewportVisibility.debugMeasures = 0;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ViewportVisibility.debugMeasures, 0);

      // A scroll: each view measured once in the frame after it moved.
      final gesture = await tester.startGesture(const Offset(100, 100));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await tester.pump();
      expect(ViewportVisibility.debugMeasures, keys.length);
      await gesture.up();
    });

    testWidgets('is as large as the preset', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      expect(tester.getSize(find.byType(ContentView)), _preset.size);
    });

    testWidgets('detaches when it leaves the tree', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      await tester.pumpWidget(host(const SizedBox()));

      expect(scope.isAttached(_sticker, _preset.spec), isFalse);
      expect(producer.attempts.single.isCancelled, isTrue);
    });

    testWidgets('does not attach again when the parent rebuilds', (
      tester,
    ) async {
      Widget view() => host(ContentView(content: _sticker, preset: _preset));

      await tester.pumpWidget(view());
      await tester.pumpWidget(view());
      await tester.pumpWidget(view());

      expect(producer.attempts, hasLength(1));
      expect(scope.isAttached(_sticker, _preset.spec), isTrue);
    });

    testWidgets('moves to the new content when it changes', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      await tester.pumpWidget(
        host(ContentView(content: _other, preset: _preset)),
      );

      expect(scope.isAttached(_sticker, _preset.spec), isFalse);
      expect(scope.isAttached(_other, _preset.spec), isTrue);
    });

    testWidgets('moves to the new spec when the preset changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final bigger = AssetPresets.square(
        extent: 40,
        devicePixelRatio: 2,
        profile: _preset.profile,
      );

      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: bigger)),
      );

      expect(scope.isAttached(_sticker, _preset.spec), isFalse);
      expect(scope.isAttached(_sticker, bigger.spec), isTrue);
      expect(tester.getSize(find.byType(ContentView)), bigger.size);
    });

    testWidgets('keeps its attach when only the profile of the preset '
        'differs in a way that does not split the entry', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );

      expect(producer.attempts, hasLength(1));
      expect(scope.isAttached(_sticker, _still.spec), isTrue);
    });

    testWidgets('moves to another scope the host provides', (tester) async {
      final other = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ticks),
      );
      addTearDown(other.dispose);
      Widget view(AssetCacheScope provided) => host(
        ContentView(content: _sticker, preset: _preset),
        provided: provided,
      );
      await tester.pumpWidget(view(scope));

      await tester.pumpWidget(view(other));

      expect(scope.isAttached(_sticker, _preset.spec), isFalse);
      expect(other.isAttached(_sticker, _preset.spec), isTrue);
    });

    testWidgets('uses the scope it is given over the provided one', (
      tester,
    ) async {
      final own = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ticks),
      );
      addTearDown(own.dispose);

      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset, scope: own)),
      );

      expect(own.isAttached(_sticker, _preset.spec), isTrue);
      expect(scope.isAttached(_sticker, _preset.spec), isFalse);
    });

    testWidgets('needs a scope from somewhere', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ContentView(content: _sticker, preset: _preset),
        ),
      );

      expect(tester.takeException(), isA<FlutterError>());
    });
  });

  group('paint', () {
    testWidgets('paints the placeholder before a stage exists', (tester) async {
      final placeholder = FakeAssetPaintable(label: 'placeholder');
      final withPlaceholder = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ticks),
        placeholder: placeholder,
      );
      addTearDown(withPlaceholder.dispose);

      await tester.pumpWidget(
        host(
          ContentView(content: _sticker, preset: _preset),
          provided: withPlaceholder,
        ),
      );

      expect(placeholder.paints, hasLength(1));
      expect(placeholder.paints.single.rect.size, _preset.size);
    });

    group('a placeholder of its own', () {
      late FakeAssetPaintable scoped;
      late AssetCacheScope withPlaceholder;

      setUp(() {
        scoped = FakeAssetPaintable(label: 'scope');
        withPlaceholder = AssetCacheScope(
          producer: producer,
          clock: PlaybackClock(ticks: ticks),
          placeholder: scoped,
        );
        addTearDown(withPlaceholder.dispose);
      });

      testWidgets('is painted before a stage exists, instead of the '
          "scope's, in the placeholder tint", (tester) async {
        final own = FakeAssetPaintable(label: 'own');
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _preset,
              placeholder: own,
              placeholderTint: const Color(0xFF445566),
            ),
            provided: withPlaceholder,
          ),
        );

        expect(scoped.paints, isEmpty);
        expect(own.paints, hasLength(1));
        expect(own.paints.single.rect.size, _preset.size);
        expect(own.paints.single.context.tint, const Color(0xFF445566));
      });

      testWidgets('takes the tint of the view without a tint of its own', (
        tester,
      ) async {
        final own = FakeAssetPaintable(label: 'own');
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _preset,
              tint: const Color(0xFF112233),
              placeholder: own,
            ),
            provided: withPlaceholder,
          ),
        );

        expect(own.paints.single.context.tint, const Color(0xFF112233));
      });

      testWidgets('stands in for a first frame the profile does not show yet, '
          "not the scope's", (tester) async {
        final own = FakeAssetPaintable(label: 'own');
        final waits = AssetPresets.square(
          extent: 20,
          devicePixelRatio: 2,
          profile: const AssetProfile(autoplayFirstFrame: false),
        );
        await tester.pumpWidget(
          host(
            ContentView(content: _sticker, preset: waits, placeholder: own),
            provided: withPlaceholder,
          ),
        );
        producer.last.advance(AssetStage.firstFrame);
        await tester.pump();
        await tester.pump(_pastFade);
        final painted = own.paints.length;

        await tester.pump(_pastFade);
        tester.renderObject(find.byType(ContentView)).markNeedsPaint();
        await tester.pump();

        expect(scoped.paints, isEmpty);
        expect(own.paints.length, greaterThan(painted));
        expect(own.paints.last.context.opacity, 1);
      });

      testWidgets('gives way to the thumbnail once one exists', (tester) async {
        final own = FakeAssetPaintable(label: 'own');
        await tester.pumpWidget(
          host(
            ContentView(content: _sticker, preset: _preset, placeholder: own),
            provided: withPlaceholder,
          ),
        );
        final thumbnail = producer.last.advance(AssetStage.placeholder);
        await tester.pump();

        expect(own.paints, hasLength(1));
        expect(thumbnail.paints, isNotEmpty);
      });

      testWidgets('is what fades out beneath content that arrives, in the '
          'placeholder tint', (tester) async {
        final own = FakeAssetPaintable(label: 'own');
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _still,
              placeholder: own,
              placeholderTint: const Color(0xFF445566),
            ),
            provided: withPlaceholder,
          ),
        );
        producer.last.advance(AssetStage.full);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));

        expect(scoped.paints, isEmpty);
        expect(own.paints.last.context.opacity, closeTo(0.5, 0.01));
        expect(own.paints.last.context.tint, const Color(0xFF445566));
      });
    });

    group('loading progress', () {
      RenderObject box(WidgetTester tester) =>
          tester.renderObject(find.byType(ContentView));

      testWidgets('is absent while nothing downloads, as for a cache hit', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _still,
              status: const MediaStatusMode.arc(12),
            ),
          ),
        );

        expect(box(tester), isNot(paints..circle(radius: 12)));

        producer.last.advance(AssetStage.placeholder);
        await tester.pump();
        expect(box(tester), isNot(paints..circle(radius: 12)));
      });

      testWidgets('is the radial progress over the centre while '
          'the content downloads, until the first frame exists', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _still,
              status: const MediaStatusMode.arc(12),
            ),
          ),
        );

        producer.last.waiting();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        // The disc of the indicator, centred over the 20 x 20 box, and its
        // arc.
        expect(
          box(tester),
          paints
            ..circle(x: 12, y: 12, radius: 12)
            ..arc(
              rect: Rect.fromCircle(center: const Offset(12, 12), radius: 8),
            ),
        );

        producer.last
          ..transfer(1, 1)
          ..advance(AssetStage.placeholder);
        await tester.pump();
        expect(box(tester), paints..circle(x: 12, y: 12, radius: 12));

        producer.last.advance(AssetStage.firstFrame);
        await tester.pump();
        await tester.pump(_controlGone);
        expect(box(tester), isNot(paints..circle(radius: 12)));
      });

      testWidgets('goes when the download fails: no arc without a retry', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _still,
              status: const MediaStatusMode.arc(12),
            ),
          ),
        );
        producer.last.transfer(3, 10);
        await tester.pump();

        producer.last.fail(StateError('offline'));
        await tester.pump();

        expect(box(tester), isNot(paints..circle(radius: 12)));
      });

      group('over a pipeline', () {
        const gif = MediaDescriptor(
          key: _sticker,
          kind: MediaKind.still,
          thumbnail: MediaThumbnailRef('thumb'),
        );
        final bytes = FetchedContent.bytes(Uint8List.fromList(const [1, 2]));
        late FakeFetcher fetcher;
        late AssetCacheScope piped;

        setUp(() {
          fetcher = FakeFetcher(autoRespond: false)
            ..serve(gif.key, bytes)
            ..serveThumbnail(gif.thumbnail!, bytes);
          final pipeline = AssetPipeline(
            fetcher: fetcher,
            decoders: DecoderRegistry()
              ..register(MediaKind.still, FakeDecoder()),
          )..know(gif);
          piped = AssetCacheScope(
            producer: pipeline,
            clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
          );
          addTearDown(pipeline.dispose);
          addTearDown(piped.dispose);
        });

        Widget view() => host(
          ContentView(
            content: gif.key,
            preset: _still,
            status: const MediaStatusMode.arc(12),
          ),
          provided: piped,
        );

        Future<void> landThumbnail(WidgetTester tester) async {
          fetcher.fetchesOf(gif.key, FetchPart.thumbnail).single.complete();
          await tester.pump();
          await tester.pump();
        }

        testWidgets('content known to be missing shows it on the first paint, '
            'before the thumbnail lands and while it shows', (tester) async {
          fetcher.missing.add(gif.key);

          await tester.pumpWidget(view());
          expect(box(tester), paints..circle(x: 12, y: 12, radius: 12));

          await landThumbnail(tester);
          expect(piped.isAttached(gif.key, _still.spec), isTrue);
          expect(box(tester), paints..circle(x: 12, y: 12, radius: 12));

          fetcher.fetchesOf(gif.key, FetchPart.content).single.complete();
          await tester.pump();
          await tester.pump();
          await tester.pump(_controlGone);
          expect(box(tester), isNot(paints..circle(radius: 12)));
        });

        testWidgets('content on the disk never shows it', (tester) async {
          await tester.pumpWidget(view());
          expect(box(tester), isNot(paints..circle(radius: 12)));

          await landThumbnail(tester);
          expect(box(tester), isNot(paints..circle(radius: 12)));

          fetcher.fetchesOf(gif.key, FetchPart.content).single.complete();
          await tester.pump();
          await tester.pump();
          expect(box(tester), isNot(paints..circle(radius: 12)));
        });

        testWidgets('a failed download hides it', (tester) async {
          fetcher.missing.add(gif.key);
          await tester.pumpWidget(view());
          await landThumbnail(tester);

          fetcher.fetchesOf(gif.key, FetchPart.content).single
            ..receive(50, 100)
            ..fail(const FetchFailure.transient('offline'));
          await tester.pump();
          await tester.pump();
          await tester.pump(_controlGone);

          expect(box(tester), isNot(paints..circle(radius: 12)));
        });
      });

      testWidgets('is absent unless asked for', (tester) async {
        await tester.pumpWidget(
          host(ContentView(content: _sticker, preset: _still)),
        );
        producer.last.transfer(5, 10);
        await tester.pump();

        expect(box(tester), isNot(paints..circle(radius: 12)));
      });

      testWidgets('asks for another frame only while it shows', (tester) async {
        await tester.pumpWidget(
          host(
            ContentView(
              content: _sticker,
              preset: _still,
              status: const MediaStatusMode.arc(12),
            ),
          ),
        );
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);

        producer.last.transfer(5, 10);
        await tester.pump();
        expect(
          tester.hasRunningAnimations || tester.binding.hasScheduledFrame,
          isTrue,
        );

        producer.last.advance(AssetStage.full);
        await tester.pump();
        await tester.pump(_pastFade);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
      });
    });

    testWidgets('paints the canned paintable into its box', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      final painted = producer.last.advance(AssetStage.full);
      await tester.pump();

      expect(painted.paints, hasLength(1));
      expect(painted.paints.single.rect.size, _preset.size);
    });

    testWidgets('repaints when a better stage arrives and not otherwise', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      await tester.pump();
      expect(thumbnail.paints, hasLength(1));

      final full = producer.last.advance(AssetStage.full);
      await tester.pump();
      await tester.pump(_pastFade);
      final painted = full.paints.length;
      await tester.pump();
      await tester.pump();

      expect(painted, greaterThan(0));
      expect(full.paints, hasLength(painted));
      expect(thumbnail.isDisposed, isTrue);
    });

    testWidgets('passes the tint and opacity on', (tester) async {
      await tester.pumpWidget(
        host(
          ContentView(
            content: _sticker,
            preset: _preset,
            tint: const Color(0xFF112233),
            opacity: 0.5,
          ),
        ),
      );

      final painted = producer.last.advance(AssetStage.full);
      await tester.pump();
      await tester.pump(_pastFade);

      final context = painted.paints.last.context;
      expect(context.tint, const Color(0xFF112233));
      expect(context.opacity, 0.5);
    });

    testWidgets('repaints when the tint changes', (tester) async {
      Widget view(Color tint) =>
          host(ContentView(content: _sticker, preset: _preset, tint: tint));
      await tester.pumpWidget(view(const Color(0xFF000000)));
      final painted = producer.last.advance(AssetStage.full);
      await tester.pump();
      final before = painted.paints.length;

      await tester.pumpWidget(view(const Color(0xFFFFFFFF)));

      expect(painted.paints.length, before + 1);
      expect(painted.paints.last.context.tint, const Color(0xFFFFFFFF));
    });
  });

  // content that arrives after the attach fades in over
  // what stood in for it, as a bitmap that is not a memory hit does (150 ms).
  group('fade', () {
    testWidgets('content that arrives after the attach rises from nothing to '
        'opaque over 150 ms', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );
      final painted = producer.last.advance(AssetStage.full);

      await tester.pump();
      expect(painted.paints.last.context.opacity, 0);
      await tester.pump(const Duration(milliseconds: 75));
      expect(painted.paints.last.context.opacity, closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 75));
      expect(painted.paints.last.context.opacity, 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('content there at the attach shows at once', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );
      final painted = producer.last.advance(AssetStage.full);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(host(const SizedBox()));

      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );

      expect(painted.paints.last.context.opacity, 1);
    });

    testWidgets('scales the opacity the view is given', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still, opacity: 0.5)),
      );
      final painted = producer.last.advance(AssetStage.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));

      expect(painted.paints.last.context.opacity, closeTo(0.25, 0.01));
    });

    testWidgets('rises over the thumbnail, which stays opaque beneath until '
        'the content is', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(thumbnail.paints.last.context.opacity, 1);
      expect(thumbnail.isDisposed, isFalse);

      await tester.pump(const Duration(milliseconds: 100));
      expect(thumbnail.isDisposed, isTrue);
    });

    testWidgets('with no thumbnail, the placeholder fades out beneath', (
      tester,
    ) async {
      final placeholder = FakeAssetPaintable(label: 'placeholder');
      final withPlaceholder = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ticks),
        placeholder: placeholder,
      );
      addTearDown(withPlaceholder.dispose);
      await tester.pumpWidget(
        host(
          ContentView(content: _sticker, preset: _still),
          provided: withPlaceholder,
        ),
      );
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(placeholder.paints.last.context.opacity, closeTo(0.5, 0.01));

      final before = placeholder.paints.length;
      await tester.pump(const Duration(milliseconds: 100));
      expect(placeholder.paints, hasLength(before));
    });

    testWidgets('a texture rises under an opacity layer', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      producer.last.advance(AssetStage.full, animated: true).textureOnAdvance =
          const AssetTexture(id: 9, width: 64, height: 64);
      await tester.pump();
      ticks.tick(const Duration(milliseconds: 16));
      // A playing view's content fades over the loop fade, 250 ms here.
      await tester.pump(const Duration(milliseconds: 125));

      final layer = _find<TextureLayer>(
        tester.binding.renderViews.first.debugLayer!,
      ).single;
      final fade = _ancestors(layer).whereType<OpacityLayer>().first;
      expect(fade.alpha, closeTo(128, 3));
    });
  });

  group('stage transitions', () {
    Widget on(TargetPlatform platform, Widget child) => Theme(
      data: ThemeData(platform: platform),
      child: host(child),
    );

    for (final (platform, length) in [
      (TargetPlatform.android, 150),
      (TargetPlatform.iOS, 200),
    ]) {
      testWidgets('${platform.name}: still content fades in over $length ms', (
        tester,
      ) async {
        await tester.pumpWidget(
          on(platform, ContentView(content: _sticker, preset: _still)),
        );
        final painted = producer.last.advance(AssetStage.full);

        await tester.pump();
        expect(painted.paints.last.context.opacity, 0);
        await tester.pump(Duration(milliseconds: length ~/ 2));
        expect(painted.paints.last.context.opacity, closeTo(0.5, 0.01));
        await tester.pump(Duration(milliseconds: length ~/ 2));
        expect(painted.paints.last.context.opacity, 1);
      });
    }

    testWidgets('a playing view fades its content over the loop fade', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _preset),
        ),
      );
      final painted = producer.last.advance(AssetStage.full, animated: true);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));

      expect(painted.paints.last.context.opacity, closeTo(0.5, 0.01));
    });

    testWidgets('desktop: no frame shows two stages blended', (tester) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.macOS,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      final preview = producer.last.advance(AssetStage.preview);
      await tester.pump();
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      final previewPaints = preview.paints.length;
      final content = producer.last.advance(AssetStage.full);
      await tester.pump();

      expect(thumbnail.paints.single.context.opacity, 1);
      expect(content.paints.single.context.opacity, 1);
      expect(preview.paints, hasLength(previewPaints));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a host changes the desktop swap into a fade', (tester) async {
      await tester.pumpWidget(
        Theme(
          data: ThemeData(platform: TargetPlatform.macOS),
          child: MediaLoadingStyleScope(
            style: (platform) => platform.copyWith(
              stages: platform.stages.copyWith(
                stageFade: const Duration(milliseconds: 100),
              ),
            ),
            child: host(ContentView(content: _sticker, preset: _still)),
          ),
        ),
      );
      final painted = producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(painted.paints.last.context.opacity, closeTo(0.5, 0.01));
    });

    testWidgets('android: the content shrinks from 1.05 to its size', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      producer.last.advance(AssetStage.full);
      RenderObject box() => tester.renderObject(find.byType(ContentView));

      await tester.pump();
      expect(box(), paints..scale(x: 1.05, y: 1.05));

      await tester.pump(const Duration(milliseconds: 150));
      expect(box(), isNot(paints..scale()));
    });

    testWidgets('iOS: the content is not scaled', (tester) async {
      await tester.pumpWidget(
        on(TargetPlatform.iOS, ContentView(content: _sticker, preset: _still)),
      );
      producer.last.advance(AssetStage.full);

      await tester.pump();

      expect(
        tester.renderObject(find.byType(ContentView)),
        isNot(paints..scale()),
      );
    });

    testWidgets('a thumbnail fades in over the preview it replaces', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      final preview = producer.last.advance(AssetStage.preview);
      await tester.pump();
      expect(preview.paints.last.context.opacity, 1);

      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));

      expect(thumbnail.paints.last.context.opacity, closeTo(0.5, 0.01));
      expect(preview.paints.last.context.opacity, 1);
      expect(preview.isDisposed, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(preview.isDisposed, isTrue);
    });

    testWidgets('a preview shows at once', (tester) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      final preview = producer.last.advance(AssetStage.preview);

      await tester.pump();

      expect(preview.paints.single.context.opacity, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a raster stand-in stays opaque under content that fades in', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      producer.last.describe(const MediaDescriptor(key: _sticker));
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));

      expect(thumbnail.paints.last.context.opacity, 1);
    });

    testWidgets('an outline stand-in fades out as the content rises', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      producer.last.describe(
        const MediaDescriptor(
          key: _sticker,
          preview: MediaPreview.outline('M0 0H1V1Z', MediaDimensions(1, 1)),
        ),
      );
      final outline = producer.last.advance(AssetStage.preview);
      await tester.pump();
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));

      expect(outline.paints.last.context.opacity, closeTo(0.5, 0.01));
    });

    testWidgets('a stand-in under a vector animation fades out', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.android,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      producer.last.describe(
        const MediaDescriptor(key: _sticker, kind: MediaKind.vectorAnimation),
      );
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      await tester.pump();
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));

      expect(thumbnail.paints.last.context.opacity, closeTo(0.5, 0.01));
    });

    testWidgets('desktop: a raster preview is washed, content is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        on(
          TargetPlatform.macOS,
          ContentView(content: _sticker, preset: _still),
        ),
      );
      producer.last.advance(AssetStage.preview);
      await tester.pump();
      RenderObject box() => tester.renderObject(find.byType(ContentView));
      expect(box(), paints..rect(color: const Color(0x30000000)));

      producer.last.advance(AssetStage.full);
      await tester.pump();
      expect(box(), isNot(paints..rect(color: const Color(0x30000000))));
    });
  });

  group('an outline preview', () {
    const outlined = MediaDescriptor(
      key: _sticker,
      preview: MediaPreview.outline('M0 0H1V1Z', MediaDimensions(1, 1)),
    );
    Widget on(TargetPlatform platform, Widget child) => Theme(
      data: ThemeData(platform: platform),
      child: host(child),
    );

    Future<FakeAssetPaintable> shown(
      WidgetTester tester,
      TargetPlatform platform, {
      Color? placeholderTint,
      bool inView = true,
    }) async {
      await tester.pumpWidget(
        on(
          platform,
          ContentView(
            content: _sticker,
            preset: _still,
            placeholderTint: placeholderTint,
            inView: inView,
          ),
        ),
      );
      producer.last.describe(outlined);
      final outline = producer.last.advance(AssetStage.preview);
      await tester.pump();
      return outline;
    }

    testWidgets('is filled as each platform fills it', (tester) async {
      for (final (platform, fill) in [
        (TargetPlatform.android, 0x46000000),
        (TargetPlatform.iOS, 0x40748391),
        (TargetPlatform.macOS, 0x40000000),
      ]) {
        final outline = await shown(tester, platform);
        expect(
          outline.paints.last.context.outline!.fill.toARGB32(),
          fill,
          reason: platform.name,
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('takes the host\'s quiet tint at the platform\'s opacity', (
      tester,
    ) async {
      final outline = await shown(
        tester,
        TargetPlatform.android,
        placeholderTint: const Color(0xFF203040),
      );

      expect(
        outline.paints.last.context.outline!.fill.toARGB32(),
        const Color(0xFF203040).withValues(alpha: 70 / 255).toARGB32(),
      );
    });

    testWidgets('iOS: shimmers while shown, a frame at a time', (tester) async {
      final outline = await shown(tester, TargetPlatform.iOS);

      expect(outline.paints.last.context.outline!.highlight, isNotNull);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(const Duration(milliseconds: 650));
      expect(outline.paints.last.context.outline!.highlight, isNotNull);
    });

    testWidgets('Android: no shimmer, no frames', (tester) async {
      final outline = await shown(tester, TargetPlatform.android);

      expect(outline.paints.last.context.outline!.highlight, isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the shimmer costs no frames while hidden', (tester) async {
      final outline = await shown(tester, TargetPlatform.iOS, inView: false);

      expect(outline.paints.last.context.outline!.highlight, isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the shimmer stands still while the clock is paused', (
      tester,
    ) async {
      scope.clock.setPaused(PlaybackPauseLayer.routeMoving, paused: true);
      addTearDown(
        () => scope.clock.setPaused(
          PlaybackPauseLayer.routeMoving,
          paused: false,
        ),
      );
      final outline = await shown(tester, TargetPlatform.iOS);

      expect(outline.paints.last.context.outline!.highlight, isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('desktop: the sticker replaces the outline at once', (
      tester,
    ) async {
      final outline = await shown(tester, TargetPlatform.macOS);
      final before = outline.paints.length;
      final sticker = producer.last.advance(AssetStage.full);

      await tester.pump();

      expect(sticker.paints.single.context.opacity, 1);
      expect(outline.paints, hasLength(before));
    });

    testWidgets('iOS: the outline fades out over 200 ms as the sticker rises', (
      tester,
    ) async {
      final outline = await shown(tester, TargetPlatform.iOS);
      producer.last.advance(AssetStage.full);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(outline.paints.last.context.opacity, closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 120));
      expect(outline.isDisposed, isTrue);
    });
  });

  group('semantics', () {
    testWidgets('is silent without a label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );

      expect(find.bySemanticsLabel(RegExp('.')), findsNothing);
      handle.dispose();
    });

    testWidgets('describes itself as an image with the label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          ContentView(
            content: _sticker,
            preset: _preset,
            semanticLabel: 'thumbs up',
          ),
        ),
      );

      expect(
        tester.getSemantics(find.bySemanticsLabel('thumbs up')),
        matchesSemantics(label: 'thumbs up', isImage: true),
      );
      handle.dispose();
    });
  });

  group('playback', () {
    testWidgets('repaints on each tick while it plays', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final painted = producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(_pastFade);
      final before = painted.paints.length;

      ticks.tick(const Duration(milliseconds: 100));
      await tester.pump();

      expect(painted.paints.length, before + 1);
    });

    testWidgets('does not repaint a still preset on ticks', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _still)),
      );
      final painted = producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(_pastFade);
      final before = painted.paints.length;

      ticks.tick(const Duration(milliseconds: 100));
      await tester.pump();

      expect(painted.paints.length, before);
    });

    testWidgets('stops while the host pauses the clock and resumes after', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final painted = producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(_pastFade);
      final before = painted.paints.length;

      scope.clock.setPaused(PlaybackPauseLayer.routeMoving, paused: true);
      ticks.tick(const Duration(milliseconds: 100));
      await tester.pump();
      expect(painted.paints.length, before);

      scope.clock.setPaused(PlaybackPauseLayer.routeMoving, paused: false);
      ticks.tick(const Duration(milliseconds: 200));
      await tester.pump();
      expect(painted.paints.length, before + 1);
    });

    testWidgets('stops while a ticker mode switches the subtree off', (
      tester,
    ) async {
      Widget view({required bool enabled}) => host(
        TickerMode(
          enabled: enabled,
          child: ContentView(content: _sticker, preset: _preset),
        ),
      );
      await tester.pumpWidget(view(enabled: true));
      final painted = producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(_pastFade);
      final before = painted.paints.length;

      await tester.pumpWidget(view(enabled: false));
      ticks.tick(const Duration(milliseconds: 100));
      await tester.pump();
      expect(painted.paints.length, before);

      await tester.pumpWidget(view(enabled: true));
      ticks.tick(const Duration(milliseconds: 200));
      await tester.pump();
      expect(painted.paints.length, greaterThan(before));
    });

    testWidgets('leaves the clock when it leaves the tree', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      expect(ticks.isRunning, isTrue);

      await tester.pumpWidget(host(const SizedBox()));

      expect(ticks.isRunning, isFalse);
    });
  });

  // the view is a render object that pushes
  // layers, so a playing asset on a platform texture is a texture layer.
  group('texture', () {
    List<TextureLayer> textures(WidgetTester tester) =>
        _find<TextureLayer>(tester.binding.renderViews.first.debugLayer!);

    testWidgets('a playing asset whose frames go to a texture is a texture '
        'layer at its box, and the view never paints it', (tester) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final playing = producer.last.advance(AssetStage.full, animated: true)
        ..textureOnAdvance = const AssetTexture(id: 9, width: 64, height: 64);
      await tester.pump();
      ticks.tick(const Duration(milliseconds: 16));
      await tester.pump();
      final paintsWithTexture = playing.paints.length;
      ticks.tick(const Duration(milliseconds: 32));
      await tester.pump();

      final layer = textures(tester).single;
      // In the coordinates of the view's own repaint boundary.
      final box = Offset.zero & _preset.size;
      expect(layer.textureId, 9);
      expect(layer.rect, box);
      expect(playing.advances, isNotEmpty);
      expect(playing.paints, hasLength(paintsWithTexture));
    });

    testWidgets('a host render object composites a binding the same way', (
      tester,
    ) async {
      final binding = scope.attach(_sticker, _preset.spec, _preset.profile)
        ..visible = true;
      addTearDown(binding.detach);
      final composited = <bool>[];
      await tester.pumpWidget(
        host(
          SizedBox.fromSize(
            size: _preset.size,
            child: _EmbedBox(binding, composited),
          ),
        ),
      );
      producer.last.advance(AssetStage.full, animated: true).textureOnAdvance =
          const AssetTexture(id: 9, width: 64, height: 64);
      tester.renderObject(find.byType(_EmbedBox)).markNeedsPaint();
      await tester.pump();

      expect(composited.last, isTrue);
      expect(textures(tester).single.textureId, 9);
    });

    testWidgets('a rounded contain preset clips its texture to the picture\'s '
        'rounded rect from the first frame, whatever the paintable knows of '
        'its size', (tester) async {
      const size = Size(40, 40);
      final rounded = AssetPreset(
        size: size,
        spec: AssetSpec.atDensity(
          logicalWidth: size.width,
          logicalHeight: size.height,
          devicePixelRatio: 2,
        ),
        profile: const AssetProfile(animate: true, cornerRadius: 6),
      );
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: rounded)),
      );
      // A landscape frame 64 x 32: letterboxed in the square box. The
      // paintable says nothing of its picture's size, as a video's first
      // frames do not.
      producer.last.advance(AssetStage.full, animated: true).textureOnAdvance =
          const AssetTexture(id: 9, width: 64, height: 32);
      await tester.pump();
      ticks.tick(const Duration(milliseconds: 16));
      await tester.pump();

      final layer = textures(tester).single;
      final clip = _ancestors(layer).whereType<ClipRRectLayer>().first;
      final box = Offset.zero & size;
      final picture = Rect.fromCenter(
        center: box.center,
        width: 40,
        height: 20,
      );
      expect(clip.clipRRect, RRect.fromRectXY(picture, 6, 6));
    });

    testWidgets('a rounded view keeps every stage inside its rounded clip '
        'in every frame of a rise: the stand-in beneath, the content before '
        'its picture size is known, and its texture under the fade', (
      tester,
    ) async {
      const size = Size(40, 40);
      const radius = 8.0;
      final rounded = AssetPreset(
        size: size,
        spec: AssetSpec.atDensity(
          logicalWidth: size.width,
          logicalHeight: size.height,
          devicePixelRatio: 1,
        ),
        profile: const AssetProfile(animate: true, cornerRadius: radius),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        host(
          RepaintBoundary(
            key: boundary,
            child: ContentView(content: _sticker, preset: rounded),
          ),
        ),
      );
      // A square picture: the rounded area is the whole box.
      const picture = Size(64, 64);
      producer.last.advance(
        AssetStage.placeholder,
        pictureSize: picture,
        fill: const Color(0xFFFF0000),
      );
      await tester.pump();
      await tester.pump(_pastFade);

      // The content arrives knowing nothing of its picture's size; its
      // texture comes a frame later.
      final content = producer.last.advance(
        AssetStage.full,
        animated: true,
        fill: const Color(0xFF0000FF),
      );

      // A texture draws nothing in a test: once the stand-in has gone only
      // the layers can tell.
      Future<void> expectRounded(String frame, {bool drawn = true}) async {
        final render = tester.renderObject(find.byKey(boundary));
        final root = render.debugLayer! as OffsetLayer;
        final pixels = await tester.runAsync(() async {
          final image = await root.toImage(Offset.zero & size);
          final bytes = await image.toByteData();
          image.dispose();
          return bytes!;
        });
        int alphaAt(int x, int y) =>
            pixels!.getUint8((y * size.width.toInt() + x) * 4 + 3);
        expect(alphaAt(0, 0), 0, reason: '$frame: the top left corner shows');
        expect(alphaAt(39, 39), 0, reason: '$frame: a corner shows');
        if (drawn) {
          expect(alphaAt(20, 20), greaterThan(0), reason: '$frame: blank');
        }
        for (final layer in [
          ..._find<PictureLayer>(root),
          ..._find<TextureLayer>(root),
        ]) {
          final clips = _ancestors(
            layer,
          ).takeWhile((up) => up != root).whereType<ClipRRectLayer>();
          expect(
            clips.any((clip) => clip.clipRRect!.tlRadiusX == radius),
            isTrue,
            reason: '$frame: $layer is outside the rounded clip',
          );
        }
      }

      await tester.pump();
      await expectRounded('first frame, no picture size');
      content.texture = const AssetTexture(id: 9, width: 64, height: 64);
      for (var i = 1; i <= 5; i++) {
        ticks.tick(Duration(milliseconds: 50 * i));
        await tester.pump(const Duration(milliseconds: 50));
        // The rise lasts 250 ms: the stand-in is gone in the last frame.
        await expectRounded('rise frame $i', drawn: i < 5);
      }
      expect(_find<TextureLayer>(tester.layers.first), isNotEmpty);
    });

    testWidgets('a cover preset fills its box with the frame and is clipped '
        'to the box', (tester) async {
      const size = Size(40, 20);
      final cover = AssetPreset(
        size: size,
        spec: AssetSpec.atDensity(
          logicalWidth: size.width,
          logicalHeight: size.height,
          devicePixelRatio: 2,
        ),
        profile: const AssetProfile(animate: true, fit: AssetFit.cover),
      );
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: cover)),
      );
      // A portrait frame of 32 x 64 centred in a square texture of 64.
      producer.last
          .advance(AssetStage.full, animated: true)
          .textureOnAdvance = const AssetTexture(
        id: 9,
        width: 64,
        height: 64,
        frameWidth: 32,
        frameHeight: 64,
      );
      await tester.pump();
      ticks.tick(const Duration(milliseconds: 16));
      await tester.pump();

      final box = Offset.zero & size;
      final layer = textures(tester).single;
      // The frame covers the 40 x 20 box at the scale 40 / 32: the whole
      // texture is then 80 x 80, centred on the box.
      expect(
        layer.rect,
        Rect.fromCenter(center: box.center, width: 80, height: 80),
      );
      final clip = _ancestors(layer).whereType<ClipRectLayer>().first;
      expect(clip.clipRect, box);
    });

    testWidgets('a canvas paint is all a still or a texture-less asset gets', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(ContentView(content: _sticker, preset: _preset)),
      );
      final playing = producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();

      expect(textures(tester), isEmpty);
      expect(playing.paints, isNotEmpty);
    });
  });
}

// The layers of type [T] under [layer], depth first.
List<T> _find<T extends Layer>(Layer layer) => [
  if (layer is T) layer,
  if (layer is ContainerLayer)
    for (
      Layer? child = layer.firstChild;
      child != null;
      child = child.nextSibling
    )
      ..._find<T>(child),
];

// The ancestors of [layer], nearest first.
List<Layer> _ancestors(Layer layer) => [
  for (Layer? up = layer.parent; up != null; up = up.parent) up,
];

/// A host's own render object that paints a binding: an inline embed.
class _EmbedBox extends LeafRenderObjectWidget {
  const _EmbedBox(this.binding, this.composited);

  final AssetBinding binding;
  final List<bool> composited;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEmbed(binding, composited);
}

class _RenderEmbed extends RenderBox {
  _RenderEmbed(this.binding, this.composited);

  final AssetBinding binding;
  final List<bool> composited;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) => composited.add(
    AssetTextureLayer.composite(context, binding, offset & size),
  );
}
