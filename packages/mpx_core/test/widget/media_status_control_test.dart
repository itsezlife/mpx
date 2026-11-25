import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/src/widget/media_status_motion.dart';
import 'package:mpx_core/testing.dart';

const _download = MediaStatus.icon(MediaStatusIcon.download);
const _cancel = MediaStatus.progress(0.4);
const _play = MediaStatus.icon(MediaStatusIcon.play);
const _pause = MediaStatus.icon(MediaStatusIcon.pause);

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  group('MediaStatus.forTransfer', () {
    const below = AssetStage.placeholder;
    const shown = AssetStage.firstFrame;

    test('none shows nothing, or play once a frame shows', () {
      expect(
        MediaStatus.forTransfer(AssetTransfer.none, below),
        isNot(predicate<MediaStatus>((status) => status.isVisible)),
      );
      expect(
        MediaStatus.forTransfer(AssetTransfer.none, shown),
        MediaStatus.none,
      );
      expect(
        MediaStatus.forTransfer(AssetTransfer.none, shown, playAction: true),
        _play,
      );
      expect(
        MediaStatus.forTransfer(AssetTransfer.none, below, playAction: true),
        MediaStatus.none,
      );
    });

    test('waiting is cancel over an arc turning without progress', () {
      expect(
        MediaStatus.forTransfer(const AssetTransfer.waiting(), below),
        const MediaStatus.progress(null),
      );
    });

    test('receiving is cancel over the bytes, turning without a total', () {
      expect(
        MediaStatus.forTransfer(const AssetTransfer.receiving(1, 4), shown),
        const MediaStatus.progress(0.25),
      );
      expect(
        MediaStatus.forTransfer(const AssetTransfer.receiving(1), below),
        const MediaStatus.progress(null),
      );
    });

    test('awaiting the user is download below the first frame', () {
      expect(
        MediaStatus.forTransfer(const AssetTransfer.awaitingUser(9), below),
        _download,
      );
    });

    test('a failure is download, the retry', () {
      expect(
        MediaStatus.forTransfer(
          const AssetTransfer.failed(AssetFailureKind.transient, 3, 9),
          shown,
        ),
        _download,
      );
    });
  });

  group('platform styles', () {
    test(r'$Android', () {
      const style = MediaStatusStyle.$Android;
      expect(style.diameter, 44);
      expect(style.compactDiameter, 24);
      expect(style.compactOffset, const Offset(8, 8));
      expect(style.discColor, const Color(0x66000000));
      expect(style.arcStroke, 3);
      expect(style.arcInset, 4);
      expect(style.minSweepDegrees, 4);
      expect(style.spinPeriod, _ms(2500));
      expect(style.spinStartDegrees, 112);
      expect(style.smoothing.duration, _ms(200));
      expect(style.smoothing.forwardOnly, isTrue);
      expect(style.spinner.turn, _ms(2000));
      expect(style.downloadCancelDuration, _ms(400));
      expect(style.downloadCancelPhases, (0.5, 0.2, 0.3));
      expect(style.playPauseDuration, _ms(300));
      expect(style.morphDuration, _ms(220));
      expect(style.disappearDuration, _ms(220));
      expect(style.appearance, MediaStatusAppearance.scale);
    });

    test(r'$IOS', () {
      const style = MediaStatusStyle.$IOS;
      expect(style.diameter, 50);
      expect(style.compactDiameter, 32);
      expect(style.roundVideoDiameter, 54);
      expect(style.discColor, Colors.black.withValues(alpha: 0.45));
      expect(style.discColorDark, Colors.black.withValues(alpha: 0.6));
      expect(style.arcStrokeAt(50), 2.25);
      expect(style.arcStrokeAt(32), 1.6);
      expect(style.arcInset, 2.5);
      expect(style.minSweepDegrees, closeTo(9.72, 0.01));
      expect(style.spinPeriod, _ms(1500));
      expect(style.smoothing.durationFor(0.1), _ms(200));
      expect(style.smoothing.durationFor(1), _ms(650));
      expect(style.morphDuration, _ms(200));
      expect(style.appearDuration, _ms(200));
      expect(style.appearance, MediaStatusAppearance.discScaleFade);
    });

    test(r'$Desktop', () {
      const style = MediaStatusStyle.$Desktop;
      expect(style.diameter, 44);
      expect(style.discColor, const Color(0x54000000));
      expect(style.discHoverColor, const Color(0x74000000));
      expect(style.hoverDuration, _ms(200));
      expect(style.arcStroke, 3);
      expect(style.arcInset, 3);
      expect(style.minSweepDegrees, 1);
      expect(style.spinPeriod, _ms(3000));
      expect(style.smoothing.constant, _ms(350));
      expect(style.spinner.turn, _ms(1000));
      expect(style.spinner.sweepPeriod, _ms(3000));
      expect(style.spinner.minSweepDegrees, 22.5);
      expect(style.spinner.maxSweepDegrees, 270);
      expect(style.appearDuration, _ms(350));
      expect(style.disappearDuration, _ms(350));
      expect(style.appearance, MediaStatusAppearance.fade);
    });

    test('copyWith changes one field and keeps the rest', () {
      final style = MediaStatusStyle.$IOS.copyWith(diameter: 60);
      expect(style.diameter, 60);
      expect(style.copyWith(diameter: 50), MediaStatusStyle.$IOS);
    });
  });

  group('motion', () {
    MediaStatusMotion motion(MediaStatus from, MediaStatusStyle style) =>
        MediaStatusMotion(from, style);

    test(r'$Android download turns into cancel in three phases', () {
      final m = motion(_download, MediaStatusStyle.$Android)
        ..retarget(_cancel)
        ..advance(_ms(100));
      expect(m.icons.single.icon, MediaStatusIcon.download);
      expect(m.icons.single.scale, closeTo(0.5, 1e-9));

      m.advance(_ms(140)); // 240 ms: the pause between the icons.
      expect(m.icons, isEmpty);

      m.advance(_ms(100)); // 340 ms: the cross half grown, turning.
      expect(m.icons.single.icon, MediaStatusIcon.cancel);
      expect(m.icons.single.scale, closeTo(0.5, 1e-9));
      expect(m.icons.single.turnDegrees, closeTo(-45, 1e-9));

      m.advance(_ms(60));
      expect(m.morph, 1);
      expect(m.icons.single.scale, 1);
    });

    test(r'$Android play and pause turn in 300 ms, others in 220 ms', () {
      final m = motion(_play, MediaStatusStyle.$Android)
        ..retarget(_pause)
        ..advance(_ms(299));
      expect(m.morph, lessThan(1));
      m.advance(_ms(1));
      expect(m.morph, 1);

      m
        ..retarget(_download)
        ..advance(_ms(219));
      expect(m.morph, lessThan(1));
      m.advance(_ms(1));
      expect(m.morph, 1);
    });

    test(r'$IOS and $Desktop scale and fade in 200 ms', () {
      for (final style in [MediaStatusStyle.$IOS, MediaStatusStyle.$Desktop]) {
        final m = motion(_download, style)
          ..retarget(_cancel)
          ..advance(_ms(100));
        expect(m.icons, hasLength(2));
        expect(m.icons.first.opacity, closeTo(0.5, 1e-9));
        expect(m.icons.last.scale, closeTo(0.5, 1e-9));
        m.advance(_ms(100));
        expect(m.morph, 1);
      }
    });

    test('a morph sent back runs back from where it is', () {
      final m = motion(_download, MediaStatusStyle.$Android)
        ..retarget(_cancel)
        ..advance(_ms(100));

      m.retarget(_download);

      expect(m.morph, closeTo(0.75, 1e-9));
      m.advance(_ms(100));
      expect(m.morph, 1);
      expect(m.icons.single.icon, MediaStatusIcon.download);
    });

    test(r'$Android smooths forward only, over 200 ms', () {
      final m = motion(
        const MediaStatus.progress(0.5),
        MediaStatusStyle.$Android,
      )..retarget(const MediaStatus.progress(0.2));
      expect(m.shownProgress, 0.2);

      m
        ..retarget(const MediaStatus.progress(0.6))
        ..advance(_ms(100));
      expect(m.shownProgress, greaterThan(0.4));
      expect(m.shownProgress, lessThan(0.6));
      m.advance(_ms(100));
      expect(m.shownProgress, 0.6);
    });

    test(r'$IOS takes longer for a large step', () {
      final m = motion(const MediaStatus.progress(0), MediaStatusStyle.$IOS)
        ..retarget(const MediaStatus.progress(0.5))
        ..advance(_ms(349));
      expect(m.shownProgress, lessThan(0.5));
      m.advance(_ms(1));
      expect(m.shownProgress, 0.5);
    });

    test(r'$Desktop closes the gap asymptotically', () {
      final m = motion(const MediaStatus.progress(0), MediaStatusStyle.$Desktop)
        ..retarget(const MediaStatus.progress(1))
        ..advance(_ms(350));
      expect(m.shownProgress, closeTo(0.5, 1e-9));
    });

    test('the arc is never shorter than the minimum sweep', () {
      final m = motion(
        const MediaStatus.progress(0),
        MediaStatusStyle.$Android,
      );
      expect(m.arc!.sweepDegrees, 4);
      expect(m.arc!.startDegrees, 112);
    });

    test('the arc turns once per period', () {
      final m = motion(
        const MediaStatus.progress(0.3),
        MediaStatusStyle.$Desktop,
      )..advance(_ms(750));
      expect(m.arc!.startDegrees, closeTo(0, 1e-9));

      final spinner = motion(
        const MediaStatus.spinner(),
        MediaStatusStyle.$Android,
      )..advance(_ms(1000));
      // A turn and a half of the period on, the chasing start has jumped
      // twice by the longest sweep (270) on top of its turn (180).
      expect(spinner.arc!.startDegrees, closeTo((112 + 180 + 270) % 360, 1e-9));
      expect(spinner.arc!.sweepDegrees, closeTo(4, 1e-9));
      spinner.advance(_ms(500));
      expect(spinner.arc!.sweepDegrees, closeTo(-266, 1e-9));
    });

    test('nothing moves once gone', () {
      final m = motion(_download, MediaStatusStyle.$Android)
        ..retarget(MediaStatus.none);
      expect(m.isAnimating, isTrue);
      m.advance(_ms(220));
      expect(m.visibility, 0);
      expect(m.isAnimating, isFalse);
    });
  });

  group('MediaStatusControl', () {
    late FakeAssetProducer producer;
    late AssetCacheScope scope;
    const key = MediaKey.remote('clip');

    setUp(() {
      producer = FakeAssetProducer();
      scope = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      );
      addTearDown(scope.dispose);
    });

    Widget host(Widget child, {TargetPlatform? platform}) => MaterialApp(
      theme: ThemeData(platform: platform ?? TargetPlatform.android),
      home: Center(child: child),
    );

    testWidgets('draws the disc and the arc of the platform', (tester) async {
      await tester.pumpWidget(host(const MediaStatusControl(status: _cancel)));

      expect(
        tester.getSize(find.byType(MediaStatusControl)),
        const Size(44, 44),
      );
      expect(
        find.byType(MediaStatusControl),
        paints
          ..circle(radius: 22, color: const Color(0x66000000))
          ..arc(
            rect: Rect.fromCircle(center: const Offset(22, 22), radius: 18),
          ),
      );

      await tester.pumpWidget(
        host(
          const MediaStatusControl(status: _cancel),
          platform: TargetPlatform.iOS,
        ),
      );
      await tester.pump(_ms(300));
      expect(
        tester.getSize(find.byType(MediaStatusControl)),
        const Size(50, 50),
      );
    });

    testWidgets('taps call the binding verb the icon names', (tester) async {
      final binding = scope.attach(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
        const AssetProfile(),
      );
      addTearDown(binding.detach);
      var plays = 0;
      await tester.pumpWidget(
        host(
          MediaStatusControl.binding(
            binding,
            playAction: true,
            onPlay: () => plays++,
          ),
        ),
      );

      producer.last.transfer(10, 100);
      await tester.pump();
      await tester.tap(find.byType(MediaStatusControl));
      expect(producer.attempts.first.isCancelled, isTrue);
      expect(binding.transfer, const AssetTransfer.awaitingUser(100, 10));

      producer.last.awaitingUser();
      await tester.pump(_ms(500));
      await tester.tap(find.byType(MediaStatusControl));
      expect(producer.attempts, hasLength(3));

      producer.last.advance(AssetStage.full);
      await tester.pump(_ms(500));
      await tester.tap(find.byType(MediaStatusControl));
      expect(plays, 1);
    });

    testWidgets('a progress change repaints without a rebuild', (tester) async {
      final binding = scope.attach(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
        const AssetProfile(),
      );
      addTearDown(binding.detach);
      await tester.pumpWidget(host(MediaStatusControl.binding(binding)));
      producer.last.transfer(10, 100);
      await tester.pump();
      final element = tester.element(find.byType(Semantics).last);
      final before = element.widget;

      producer.last.transfer(50, 100);
      await tester.pump();

      expect(tester.element(find.byType(Semantics).last).widget, same(before));
    });

    testWidgets('asks for no frame once it has gone', (tester) async {
      await tester.pumpWidget(
        host(const MediaStatusControl(status: _download)),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pumpWidget(
        host(const MediaStatusControl(status: MediaStatus.none)),
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(_ms(300));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a plain status calls onTap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(MediaStatusControl(status: _download, onTap: () => taps++)),
      );

      await tester.tap(find.byType(MediaStatusControl));

      expect(taps, 1);
      expect(find.bySemanticsLabel('Download'), findsOneWidget);
    });
  });

  group('MediaLoadingStyleScope', () {
    testWidgets('resolves the theme platform and applies the host change', (
      tester,
    ) async {
      late MediaLoadingStyle resolved;
      await tester.pumpWidget(
        Theme(
          data: ThemeData(platform: TargetPlatform.iOS),
          child: MediaLoadingStyleScope(
            style: (platform) => platform.copyWith(
              status: platform.status.copyWith(discColor: Colors.red),
            ),
            child: Builder(
              builder: (context) {
                resolved = MediaLoadingStyleScope.resolve(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(resolved.status.discColor, Colors.red);
      expect(resolved.status.diameter, 50);
    });

    test('forPlatform', () {
      expect(
        MediaLoadingStyle.forPlatform(TargetPlatform.android),
        MediaLoadingStyle.$Android,
      );
      expect(
        MediaLoadingStyle.forPlatform(TargetPlatform.linux),
        MediaLoadingStyle.$Desktop,
      );
    });
  });
}
