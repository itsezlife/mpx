import 'dart:async';

import 'dart:ui' show PointerChange, PointerData, PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/lab/pointer_tape.dart';

/// A pointer row at [micros] (the tape's 21 numbers).
PointerRow _row(int micros, PointerChange change, double y) => PointerRow([
  micros,
  change.index,
  PointerDeviceKind.touch.index,
  0,
  1,
  7,
  500,
  y,
  0,
  0,
  1,
  1,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
]);

/// A drag of 13 samples 8 ms apart, an idle second, a tap, then Back.
List<TapeRow> _session() => [
  _row(1000000, PointerChange.down, 1500),
  for (var i = 1; i <= 12; i++)
    _row(1000000 + i * 8000, PointerChange.move, 1500 - i * 40.0),
  _row(1104000, PointerChange.up, 1020),
  _row(2104000, PointerChange.down, 800),
  _row(2160000, PointerChange.up, 800),
  const BackRow(2600000),
];

const _window = TapeWindow(
  width: 1080,
  height: 2340,
  devicePixelRatio: 2.8125,
  paddingTop: 110,
  paddingBottom: 132,
);

/// Replays [rows] under the test's frame clock, a frame every 8 ms, and
/// returns what was dispatched: each packet's samples with the frame time
/// they went out at, and the Backs.
Future<List<(Duration, List<PointerData>)>> _replay(
  WidgetTester tester,
  List<TapeRow> rows,
  List<Duration> backs,
) async {
  final sent = <(Duration, List<PointerData>)>[];
  var now = Duration.zero;
  var done = false;
  unawaited(
    PointerTape.play(
      rows,
      forward: (packet) => sent.add((now, packet.data)),
      back: () => backs.add(now),
    ).then((_) => done = true),
  );
  for (var i = 0; i < 600 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 8));
    now += const Duration(milliseconds: 8);
  }
  expect(done, isTrue, reason: 'the replay ends');
  return sent;
}

void main() {
  test('a tape survives its file', () {
    final tape = Tape(_window, 'home', _session());
    final back = Tape.decode(tape.encode());
    expect(back.window, _window);
    expect(back.start, 'home');
    expect(back.rows, hasLength(_session().length));
    expect(back.rows.last, isA<BackRow>());
    expect(
      [for (final r in back.rows) r.time],
      [for (final r in _session()) r.time],
    );
  });

  test('a window differs by any of its measures', () {
    expect(
      _window,
      isNot(
        const TapeWindow(
          width: 1080,
          height: 2340,
          devicePixelRatio: 2.8125,
          paddingTop: 110,
          paddingBottom: 0,
        ),
      ),
    );
  });

  testWidgets('a replay keeps the order and spacing of the rows', (
    tester,
  ) async {
    final backs = <Duration>[];
    final sent = await _replay(tester, _session(), backs);
    final samples = [for (final (_, data) in sent) ...data];
    final pointerRows = _session().whereType<PointerRow>().toList();
    expect(samples, hasLength(pointerRows.length));
    expect(
      [for (final s in samples) s.physicalY],
      [for (final r in pointerRows) r.values[7]],
    );
    // The timestamps keep the recorded intervals.
    final t0 = samples.first.timeStamp;
    expect(
      [for (final s in samples) (s.timeStamp - t0).inMicroseconds],
      [for (final r in pointerRows) r.time - pointerRows.first.time],
    );
    expect(backs, hasLength(1));
  });

  testWidgets('each row goes out with the first frame due after it', (
    tester,
  ) async {
    final backs = <Duration>[];
    final sent = await _replay(tester, _session(), backs);
    final start = sent.first.$1;
    for (final (at, data) in sent) {
      for (final s in data) {
        final due = Duration(
          microseconds:
              (s.timeStamp - sent.first.$2.first.timeStamp).inMicroseconds,
        );
        final late = at - start - due;
        expect(late, greaterThanOrEqualTo(Duration.zero));
        // Within a gesture a frame takes its rows; after an idle stretch the
        // timer wakes the frames a little before the row is due.
        expect(late, lessThan(const Duration(milliseconds: 9)));
      }
    }
  });

  testWidgets('two replays dispatch the same packets', (tester) async {
    final first = await _replay(tester, _session(), []);
    final second = await _replay(tester, _session(), []);
    expect(
      [for (final (_, d) in second) d.length],
      [for (final (_, d) in first) d.length],
    );
  });

  test('an empty tape plays nothing', () async {
    expect(
      await PointerTape.play(
        const [],
        forward: (_) => fail('no packet'),
        back: () => fail('no Back'),
      ),
      0,
    );
  });
}
