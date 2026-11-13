import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

void main() {
  group('which policy a viewer follows', () {
    Future<ViewerPolicy> resolved(
      WidgetTester tester, {
      TargetPlatform? platform,
      ViewerPolicy Function(ViewerPolicy platformDefault)? scope,
      ViewerPolicy? policy,
    }) async {
      final harness = ViewerHarness();
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() {
        harness.scope.dispose();
        harness.clock.dispose();
        harness.source.dispose();
      });
      Widget viewer = MediaViewer(
        source: harness.source,
        initialIndex: 0,
        scope: harness.scope,
        policy: policy,
      );
      if (scope != null)
        viewer = ViewerPolicyScope(policy: scope, child: viewer);
      if (platform != null) {
        viewer = Theme(
          data: ThemeData(platform: platform),
          child: viewer,
        );
      }
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: viewer),
      );
      return harness.state(tester).policy;
    }

    testWidgets('with nothing set, the reference of the theme\'s platform', (
      tester,
    ) async {
      expect(
        await resolved(tester, platform: TargetPlatform.iOS),
        same(ViewerPolicy.$IOS),
      );
      expect(
        await resolved(tester, platform: TargetPlatform.macOS),
        same(ViewerPolicy.$Desktop),
      );
      expect(
        await resolved(tester, platform: TargetPlatform.android),
        same(ViewerPolicy.$Android),
      );
    });

    testWidgets('a scope changes the platform\'s reference and keeps the '
        'rest of it', (tester) async {
      final policy = await resolved(
        tester,
        platform: TargetPlatform.iOS,
        scope: (platform) => platform.copyWith(pageGap: 99),
      );

      expect(policy.pageGap, 99);
      expect(policy.openStyle, ViewerPolicy.$IOS.openStyle);
      expect(policy.video, same(ViewerPolicy.$IOS.video));
    });

    testWidgets('a scope may replace it whole', (tester) async {
      expect(
        await resolved(
          tester,
          platform: TargetPlatform.iOS,
          scope: (_) => ViewerPolicy.$Desktop,
        ),
        same(ViewerPolicy.$Desktop),
      );
    });

    testWidgets('the viewer\'s own policy wins over the scope', (tester) async {
      expect(
        await resolved(
          tester,
          platform: TargetPlatform.iOS,
          scope: (_) => ViewerPolicy.$Desktop,
          policy: ViewerPolicy.$Android,
        ),
        same(ViewerPolicy.$Android),
      );
    });
  });

  group('copyWith', () {
    test('changes the fields given and keeps every other', () {
      const android = ViewerPolicy.$Android;
      final changed = android.copyWith(
        maxZoom: 5,
        video: android.video.copyWith(
          start: ViewerVideoStart.origin,
          speed: android.video.speed.copyWith(max: 4),
          doubleTapSeek: android.video.doubleTapSeek!.copyWith(
            step: const Duration(seconds: 5),
          ),
        ),
        chrome: android.chrome.copyWith(topBarHeight: 64),
      );

      expect(changed.maxZoom, 5);
      expect(changed.minZoom, android.minZoom);
      expect(changed.openStyle, android.openStyle);
      expect(changed.video.start, ViewerVideoStart.origin);
      expect(changed.video.originReturn, android.video.originReturn);
      expect(changed.video.loopOpen, android.video.loopOpen);
      expect(changed.video.speed.max, 4);
      expect(changed.video.speed.min, android.video.speed.min);
      expect(changed.video.speed.presets, android.video.speed.presets);
      expect(changed.video.doubleTapSeek!.step, const Duration(seconds: 5));
      expect(
        changed.video.doubleTapSeek!.minDuration,
        android.video.doubleTapSeek!.minDuration,
      );
      expect(changed.chrome.topBarHeight, 64);
      expect(changed.chrome.counterGap, android.chrome.counterGap);

      const hold = ViewerHoldSpeed(delay: Duration(milliseconds: 200));
      final faster = hold.copyWith(maxRate: 3);
      expect(faster.maxRate, 3);
      expect(faster.delay, hold.delay);
    });

    test('the platforms\' choices for a video and an animation', () {
      for (final policy in [
        ViewerPolicy.$Android,
        ViewerPolicy.$IOS,
        ViewerPolicy.$Desktop,
      ]) {
        expect(policy.video.start, ViewerVideoStart.beginning);
      }
      expect(
        ViewerPolicy.$Android.video.originReturn,
        ViewerOriginReturn.atPlayer,
      );
      expect(
        ViewerPolicy.$Desktop.video.originReturn,
        ViewerOriginReturn.atPlayer,
      );
      expect(ViewerPolicy.$IOS.video.originReturn, ViewerOriginReturn.restart);
      expect(ViewerPolicy.$Android.video.loopOpen, ViewerLoopOpen.continues);
      expect(ViewerPolicy.$Desktop.video.loopOpen, ViewerLoopOpen.continues);
      expect(ViewerPolicy.$IOS.video.loopOpen, ViewerLoopOpen.restart);
    });
  });
}
