import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

void main() {
  const style = MediaStatusStyle.$Android;

  group('a painter of its own draws the control\'s arcs', () {
    test('the spinner starts short at the style\'s start, and is longest '
        'half a swing on', () {
      final first = MediaStatusPainting.spinnerArc(style, Duration.zero);
      expect(first.startDegrees, style.spinStartDegrees);
      expect(first.sweepDegrees, style.spinner.minSweepDegrees);

      final half = style.spinner.sweepPeriod ~/ 2;
      expect(
        MediaStatusPainting.spinnerArc(style, half).sweepDegrees,
        closeTo(style.spinner.maxSweepDegrees, 0.001),
      );
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
