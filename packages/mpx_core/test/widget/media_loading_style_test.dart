import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  group('MediaStageStyle', () {
    test('Android: 150 ms linear fades, no scale-in, 250 ms for loops', () {
      const style = MediaStageStyle.$Android;
      expect(style.fill, isNull);
      expect(style.stageFade, const Duration(milliseconds: 150));
      expect(style.gifFade, const Duration(milliseconds: 250));
      expect(style.contentScaleIn, 0);
      expect(style.previewWash, isNull);
      expect(style.outlineFill, const Color(0x46000000));
      expect(style.outlineTintOpacity, 70 / 255);
      expect(style.outlineShimmer, isNull);
      expect(style.roundPreviewScale, 1.2);
    });

    test('iOS: 200 ms fades, no scale-in, a 1.3 s outline sweep', () {
      const style = MediaStageStyle.$IOS;
      expect(style.fill, isNull);
      expect(style.stageFade, const Duration(milliseconds: 200));
      expect(style.gifFade, const Duration(milliseconds: 200));
      expect(style.contentScaleIn, 0);
      expect(style.previewWash, isNull);
      expect(style.outlineFill, const Color(0x40748391));
      expect(style.outlineTintOpacity, 0.25);
      expect(
        style.outlineShimmer,
        const OutlineShimmer(
          sweep: Duration(milliseconds: 1300),
          curve: Curves.easeOut,
        ),
      );
      expect(style.roundPreviewScale, 1.2);
    });

    test('desktop: hard swaps, a black wash over previews, a slide and a '
        'wait', () {
      const style = MediaStageStyle.$Desktop;
      expect(style.fill, isNull);
      expect(style.stageFade, Duration.zero);
      expect(style.gifFade, Duration.zero);
      expect(style.contentScaleIn, 0);
      expect(style.previewWash, const Color(0x30000000));
      expect(style.outlineFill, const Color(0x40000000));
      expect(style.outlineTintOpacity, 1);
      expect(
        style.outlineShimmer,
        const OutlineShimmer(
          sweep: Duration(milliseconds: 1000),
          wait: Duration(milliseconds: 1000),
        ),
      );
      expect(style.roundPreviewScale, 1.2);
    });

    test('copyWith changes one field and keeps the rest', () {
      final faded = MediaStageStyle.$Desktop.copyWith(
        stageFade: const Duration(milliseconds: 90),
      );
      expect(faded.stageFade, const Duration(milliseconds: 90));
      expect(faded.previewWash, MediaStageStyle.$Desktop.previewWash);
      expect(faded, isNot(MediaStageStyle.$Desktop));
      expect(MediaStageStyle.$Desktop.copyWith(), MediaStageStyle.$Desktop);
    });

    test('copyWith clears a colour with its clear flag', () {
      final washless = MediaStageStyle.$Desktop.copyWith(
        clearPreviewWash: true,
      );
      expect(washless.previewWash, isNull);
      final filled = MediaStageStyle.$Android.copyWith(
        fill: const Color(0xFF223344),
      );
      expect(filled.fill, const Color(0xFF223344));
      expect(filled.copyWith(clearFill: true).fill, isNull);
    });
  });

  group('MediaLoadingStyle', () {
    test('forPlatform maps each platform', () {
      expect(
        MediaLoadingStyle.forPlatform(TargetPlatform.android),
        MediaLoadingStyle.$Android,
      );
      expect(
        MediaLoadingStyle.forPlatform(TargetPlatform.fuchsia),
        MediaLoadingStyle.$Android,
      );
      expect(
        MediaLoadingStyle.forPlatform(TargetPlatform.iOS),
        MediaLoadingStyle.$IOS,
      );
      for (final desktop in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          MediaLoadingStyle.forPlatform(desktop),
          MediaLoadingStyle.$Desktop,
        );
      }
    });

    test('each platform holds its stage style', () {
      expect(MediaLoadingStyle.$Android.stages, MediaStageStyle.$Android);
      expect(MediaLoadingStyle.$IOS.stages, MediaStageStyle.$IOS);
      expect(MediaLoadingStyle.$Desktop.stages, MediaStageStyle.$Desktop);
    });

    test('copyWith replaces the stage style', () {
      final style = MediaLoadingStyle.$IOS.copyWith(
        stages: MediaStageStyle.$Desktop,
      );
      expect(style.stages, MediaStageStyle.$Desktop);
    });
  });

  group('MediaLoadingStyleScope', () {
    Future<MediaLoadingStyle> resolved(
      WidgetTester tester,
      TargetPlatform platform, {
      MediaLoadingStyle Function(MediaLoadingStyle platform)? scope,
      MediaLoadingStyle? own,
    }) async {
      late MediaLoadingStyle style;
      Widget child = Builder(
        builder: (context) {
          style = MediaLoadingStyleScope.resolve(context, style: own);
          return const SizedBox();
        },
      );
      if (scope != null) {
        child = MediaLoadingStyleScope(style: scope, child: child);
      }
      await tester.pumpWidget(
        Theme(
          data: ThemeData(platform: platform),
          child: child,
        ),
      );
      return style;
    }

    testWidgets('without a scope is the theme platform\'s style', (
      tester,
    ) async {
      expect(
        await resolved(tester, TargetPlatform.macOS),
        MediaLoadingStyle.$Desktop,
      );
      expect(
        await resolved(tester, TargetPlatform.iOS),
        MediaLoadingStyle.$IOS,
      );
    });

    testWidgets('a scope changes one field of the platform style', (
      tester,
    ) async {
      final style = await resolved(
        tester,
        TargetPlatform.macOS,
        scope: (platform) => platform.copyWith(
          stages: platform.stages.copyWith(
            stageFade: const Duration(milliseconds: 120),
          ),
        ),
      );

      expect(style.stages.stageFade, const Duration(milliseconds: 120));
      expect(style.stages.previewWash, MediaStageStyle.$Desktop.previewWash);
    });

    testWidgets('a widget\'s own style wins over the scope', (tester) async {
      final style = await resolved(
        tester,
        TargetPlatform.macOS,
        scope: (_) => MediaLoadingStyle.$Android,
        own: MediaLoadingStyle.$IOS,
      );

      expect(style, MediaLoadingStyle.$IOS);
    });
  });
}
