import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
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
// Long enough for content that arrived after the attach to have faded in.
const _pastFade = Duration(milliseconds: 160);

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
            ContentView(content: _sticker, preset: _still, loadingRadius: 12),
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
            ContentView(content: _sticker, preset: _still, loadingRadius: 12),
          ),
        );

        producer.last.waiting();
        await tester.pump();
        // The disc of the indicator, centred in the 20 x 20 box, and its arc.
        expect(
          box(tester),
          paints
            ..circle(x: 10, y: 10, radius: 12)
            ..arc(
              rect: Rect.fromCircle(center: const Offset(10, 10), radius: 8),
            ),
        );

        producer.last
          ..transfer(1, 1)
          ..advance(AssetStage.placeholder);
        await tester.pump();
        expect(box(tester), paints..circle(x: 10, y: 10, radius: 12));

        producer.last.advance(AssetStage.firstFrame);
        await tester.pump();
        expect(box(tester), isNot(paints..circle(radius: 12)));
      });

      testWidgets('goes when the download fails: no arc without a retry', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            ContentView(content: _sticker, preset: _still, loadingRadius: 12),
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
          ContentView(content: gif.key, preset: _still, loadingRadius: 12),
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
          expect(box(tester), paints..circle(x: 10, y: 10, radius: 12));

          await landThumbnail(tester);
          expect(piped.isAttached(gif.key, _still.spec), isTrue);
          expect(box(tester), paints..circle(x: 10, y: 10, radius: 12));

          fetcher.fetchesOf(gif.key, FetchPart.content).single.complete();
          await tester.pump();
          await tester.pump();
          await tester.pump(_pastFade);
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
            ContentView(content: _sticker, preset: _still, loadingRadius: 12),
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
      await tester.pump(const Duration(milliseconds: 75));

      final layer = _find<TextureLayer>(
        tester.binding.renderViews.first.debugLayer!,
      ).single;
      final fade = _ancestors(layer).whereType<OpacityLayer>().first;
      expect(fade.alpha, closeTo(128, 3));
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
