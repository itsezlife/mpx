import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _clip = MediaKey.remote('round');
const _bubble = Color(0xFF3390EC);

// A round video message: a circle of 200, playing.
final _round = AssetPresets.round(
  diameter: 200,
  devicePixelRatio: 1,
  profile: const AssetProfile(animate: true),
);

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

  Widget host(TargetPlatform platform, Widget child) => Theme(
    data: ThemeData(platform: platform),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: AssetCacheProvider(
        scope: scope,
        child: Center(child: child),
      ),
    ),
  );

  RenderObject box(WidgetTester tester) =>
      tester.renderObject(find.byType(ContentView));

  group('AssetPresets.round', () {
    test('is a square whose profile clips a circle', () {
      final preset = AssetPresets.round(
        diameter: 100,
        devicePixelRatio: 2,
        profile: const AssetProfile(animate: true),
      );

      expect(preset.size, const Size.square(100));
      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (200, 200));
      expect(preset.profile.cornerRadius, 50);
      expect(preset.profile.animate, isTrue);
      expect(preset.isRound, isTrue);
    });

    test('a square with smaller corners is not round', () {
      final preset = AssetPresets.square(
        extent: 100,
        devicePixelRatio: 1,
        profile: const AssetProfile(cornerRadius: 12),
      );

      expect(preset.isRound, isFalse);
    });
  });

  group('a round view', () {
    testWidgets('fills its circle in the host tint before anything exists', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(content: _clip, preset: _round, underlay: _bubble),
        ),
      );

      expect(
        box(tester),
        paints..rrect(
          rrect: RRect.fromRectAndRadius(
            Offset.zero & const Size.square(200),
            const Radius.circular(100),
          ),
          color: _bubble,
        ),
      );
    });

    testWidgets('keeps the fill under its preview and under the content '
        'while it fades in, then stops painting it', (tester) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(content: _clip, preset: _round, underlay: _bubble),
        ),
      );
      producer.last.advance(AssetStage.preview);
      await tester.pump();
      expect(box(tester), paints..rrect(color: _bubble));

      producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(box(tester), paints..rrect(color: _bubble));

      await tester.pump(const Duration(milliseconds: 200));
      expect(box(tester), isNot(paints..rrect(color: _bubble)));
    });

    testWidgets('content there at the attach shows no fill', (tester) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(content: _clip, preset: _round),
        ),
      );
      producer.last.advance(AssetStage.full, animated: true);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(
            key: const ValueKey('again'),
            content: _clip,
            preset: _round,
            underlay: _bubble,
          ),
        ),
      );

      expect(box(tester), isNot(paints..rrect(color: _bubble)));
    });

    testWidgets('draws its preview 1.2 times larger inside the circle', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(content: _clip, preset: _round),
        ),
      );
      final preview = producer.last.advance(AssetStage.preview);
      await tester.pump();

      expect(
        box(tester),
        paints
          ..clipRRect(
            rrect: RRect.fromRectAndRadius(
              Offset.zero & const Size.square(200),
              const Radius.circular(100),
            ),
          )
          ..scale(x: 1.2, y: 1.2),
      );
      expect(preview.paints.last.rect, Offset.zero & const Size.square(200));
    });

    testWidgets('a host style changes the preview scale', (tester) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          MediaLoadingStyleScope(
            style: (platform) => platform.copyWith(
              stages: platform.stages.copyWith(roundPreviewScale: 1.5),
            ),
            child: ContentView(content: _clip, preset: _round),
          ),
        ),
      );
      producer.last.advance(AssetStage.preview);
      await tester.pump();

      expect(box(tester), paints..scale(x: 1.5, y: 1.5));
    });

    testWidgets('draws its content unscaled once it is in', (tester) async {
      await tester.pumpWidget(
        host(TargetPlatform.iOS, ContentView(content: _clip, preset: _round)),
      );
      producer.last.advance(AssetStage.preview);
      await tester.pump();
      producer.last.advance(AssetStage.full, animated: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(box(tester), isNot(paints..scale()));
    });

    testWidgets('a square view draws its preview unscaled', (tester) async {
      await tester.pumpWidget(
        host(
          TargetPlatform.android,
          ContentView(
            content: _clip,
            preset: AssetPresets.square(
              extent: 200,
              devicePixelRatio: 1,
              profile: const AssetProfile(cornerRadius: 12),
            ),
          ),
        ),
      );
      producer.last.advance(AssetStage.preview);
      await tester.pump();

      expect(box(tester), isNot(paints..scale()));
    });

    for (final (platform, diameter) in [
      (TargetPlatform.android, 44.0),
      (TargetPlatform.iOS, 54.0),
      (TargetPlatform.macOS, 44.0),
    ]) {
      testWidgets('${platform.name}: its control is the round size, '
          '$diameter', (tester) async {
        await tester.pumpWidget(
          host(
            platform,
            ContentView(
              content: _clip,
              preset: _round,
              status: const MediaStatusMode.control(),
            ),
          ),
        );
        producer.last.awaitingUser();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          tester.getSize(find.byType(MediaStatusControl)),
          Size.square(diameter),
        );
      });
    }
  });

  test('the round buffering spinner waits 750 ms on iOS, 500 elsewhere', () {
    expect(
      MediaStatusStyle.$IOS.roundBufferingDelay,
      const Duration(milliseconds: 750),
    );
    expect(
      MediaStatusStyle.$Android.roundBufferingDelay,
      const Duration(milliseconds: 500),
    );
    expect(
      MediaStatusStyle.$Desktop.roundBufferingDelay,
      const Duration(milliseconds: 500),
    );
    expect(
      MediaStatusStyle.$IOS
          .copyWith(roundBufferingDelay: Duration.zero)
          .roundBufferingDelay,
      Duration.zero,
    );
  });
}
