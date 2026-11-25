import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

void main() {
  const style = MediaStatusStyle.$Android;

  group('a painter of its own draws the control\'s arcs', () {
    test('the swinging spinner starts short at the style\'s start, and is '
        'longest half a swing on', () {
      const swing = MediaStatusStyle.$IOS;
      expect(swing.spinner.motion, MediaSpinnerMotion.swing);
      final first = MediaStatusPainting.spinnerArc(swing, Duration.zero);
      expect(first.startDegrees, swing.spinStartDegrees % 360);
      expect(first.sweepDegrees, swing.spinner.minSweepDegrees);

      final half = swing.spinner.sweepPeriod ~/ 2;
      expect(
        MediaStatusPainting.spinnerArc(swing, half).sweepDegrees,
        closeTo(swing.spinner.maxSweepDegrees, 0.001),
      );
    });

    test('the chasing spinner grows its head, accelerating, then jumps its '
        'start and draws backwards, its tail decelerating onto the head', () {
      expect(style.spinner.motion, MediaSpinnerMotion.chase);
      MediaStatusArc at(int ms) =>
          MediaStatusPainting.spinnerArc(style, Duration(milliseconds: ms));

      expect(at(0).startDegrees, style.spinStartDegrees);
      expect(at(0).sweepDegrees, 4);
      // 4 + 266 * (1/2)^2: slow at first.
      expect(at(250).sweepDegrees, closeTo(70.5, 0.001));
      expect(at(499).sweepDegrees, closeTo(270, 2));
      // Half a period on: the start has jumped by the longest sweep on top of
      // its turn (a quarter of a turn here), and the arc runs backwards.
      expect(at(500).sweepDegrees, closeTo(-266, 0.001));
      expect(
        at(500).startDegrees,
        closeTo((style.spinStartDegrees + 90 + 270) % 360, 0.001),
      );
      // 4 - 270 * (1/2)^2: the tail has covered three quarters of its way.
      expect(at(750).sweepDegrees, closeTo(-63.5, 0.001));
      expect(at(1000).sweepDegrees, closeTo(4, 0.001));
      expect(at(1000).startDegrees, closeTo((112 + 180 + 270) % 360, 0.001));
      // The jump comes once per period.
      expect(at(1500).startDegrees, closeTo((112 + 270 + 540) % 360, 0.001));
    });

    test('a fraction sweeps its share of the turn, never below the '
        'shortest arc', () {
      expect(MediaStatusPainting.progressArc(style, 0.5, Duration.zero), (
        startDegrees: style.spinStartDegrees,
        sweepDegrees: 180.0,
      ));
      expect(
        MediaStatusPainting.progressArc(style, 0, Duration.zero).sweepDegrees,
        style.minSweepDegrees,
      );
    });

    testWidgets('paint draws the disc and the arc', (tester) async {
      await tester.pumpWidget(
        Center(
          child: CustomPaint(
            size: const Size(44, 44),
            painter: _Arc(
              MediaStatusPainting.progressArc(style, 0.25, Duration.zero),
            ),
          ),
        ),
      );

      expect(
        find.byType(CustomPaint),
        paints
          ..circle(radius: 22)
          ..arc(),
      );
    });
  });

  testWidgets('the overlay lays a binding\'s control over what paints it', (
    tester,
  ) async {
    final producer = FakeAssetProducer();
    final scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
    addTearDown(scope.dispose);
    final binding = scope.attach(
      const MediaKey.remote('embed'),
      const AssetSpec(pixelWidth: 64, pixelHeight: 64),
      const AssetProfile(),
    );
    addTearDown(binding.detach);
    producer.last.awaitingUser();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 120,
          height: 120,
          child: AssetStatusOverlay(
            binding: binding,
            badge: true,
            child: const Text('picture'),
          ),
        ),
      ),
    );

    expect(find.text('picture'), findsOneWidget);
    expect(find.bySemanticsLabel('Download'), findsOneWidget);
    expect(find.byType(MediaBadge), findsOneWidget);
  });
}

class _Arc extends CustomPainter {
  _Arc(this.arc);

  final MediaStatusArc arc;

  @override
  void paint(Canvas canvas, Size size) => MediaStatusPainting.paint(
    canvas,
    size.center(Offset.zero),
    size.shortestSide,
    MediaStatusStyle.$Android,
    arc: arc,
  );

  @override
  bool shouldRepaint(_Arc oldDelegate) => oldDelegate.arc != arc;
}
