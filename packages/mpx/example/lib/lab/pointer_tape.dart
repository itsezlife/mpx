import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui'
    show
        PlatformDispatcher,
        PointerChange,
        PointerData,
        PointerDataPacket,
        PointerDeviceKind,
        PointerSignalKind;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The window a tape was recorded in. A replay in another window would land
/// its taps on other targets, so it refuses to start.
@immutable
final class TapeWindow {
  const TapeWindow({
    required this.width,
    required this.height,
    required this.devicePixelRatio,
    required this.paddingTop,
    required this.paddingBottom,
  });

  /// The window of the first view now.
  factory TapeWindow.now() {
    final view = PlatformDispatcher.instance.views.first;
    return TapeWindow(
      width: view.physicalSize.width,
      height: view.physicalSize.height,
      devicePixelRatio: view.devicePixelRatio,
      paddingTop: view.padding.top,
      paddingBottom: view.padding.bottom,
    );
  }

  factory TapeWindow.fromJson(Map<String, Object?> json) => TapeWindow(
    width: (json['width']! as num).toDouble(),
    height: (json['height']! as num).toDouble(),
    devicePixelRatio: (json['dpr']! as num).toDouble(),
    paddingTop: (json['paddingTop']! as num).toDouble(),
    paddingBottom: (json['paddingBottom']! as num).toDouble(),
  );

  final double width;
  final double height;
  final double devicePixelRatio;
  final double paddingTop;
  final double paddingBottom;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'dpr': devicePixelRatio,
    'paddingTop': paddingTop,
    'paddingBottom': paddingBottom,
  };

  @override
  bool operator ==(Object other) =>
      other is TapeWindow &&
      other.width == width &&
      other.height == height &&
      other.devicePixelRatio == devicePixelRatio &&
      other.paddingTop == paddingTop &&
      other.paddingBottom == paddingBottom;

  @override
  int get hashCode =>
      Object.hash(width, height, devicePixelRatio, paddingTop, paddingBottom);

  @override
  String toString() =>
      '${width.round()}x${height.round()}@$devicePixelRatio '
      'pad=${paddingTop.round()}/${paddingBottom.round()}';
}

/// One tape row on the engine's monotonic clock, in microseconds.
sealed class TapeRow {
  const TapeRow();

  int get time;
}

/// A pointer sample: [values] is the 21-number row of [PointerTape].
final class PointerRow extends TapeRow {
  const PointerRow(this.values);

  final List<num> values;

  @override
  int get time => values[0].toInt();
}

/// A system Back (`popRoute`): a gesture or button the app sees without a
/// pointer packet.
final class BackRow extends TapeRow {
  const BackRow(this.time);

  @override
  final int time;
}

/// A recorded session: the window and the route it was recorded from, and
/// its rows.
///
/// The file is `{"window": {...}, "start": "home", "rows": [...]}`; a
/// pointer row is an array of 21 numbers (see [PointerTape]), a Back is
/// `{"t": 123, "e": "back"}` (engine microseconds). Rows share one clock
/// and are in time order.
final class Tape {
  const Tape(this.window, this.start, this.rows);

  factory Tape.decode(String text) {
    final json = jsonDecode(text) as Map<String, Object?>;
    return Tape(
      TapeWindow.fromJson(json['window']! as Map<String, Object?>),
      json['start']! as String,
      [
        for (final row in json['rows']! as List<Object?>)
          switch (row) {
            final List<Object?> values => PointerRow([...values.cast<num>()]),
            {'t': final num t, 'e': 'back'} => BackRow(t.toInt()),
            _ => throw FormatException('Unknown tape row', row),
          },
      ],
    );
  }

  final TapeWindow window;

  /// The route on top when the recording started.
  final String start;
  final List<TapeRow> rows;

  String encode() => jsonEncode({
    'window': window.toJson(),
    'start': start,
    'rows': [
      for (final row in [...rows]..sort((a, b) => a.time.compareTo(b.time)))
        switch (row) {
          PointerRow(:final values) => values,
          BackRow(:final time) => {'t': time, 'e': 'back'},
        },
    ],
  });
}

/// Why a replay did not run.
final class TapeRefused implements Exception {
  const TapeRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Records the pointer packets the engine hands the framework, and system
/// Back, and plays them back with their original spacing.
///
/// Sits in front of the binding's `onPointerDataPacket`, so a replay goes
/// through the same hit testing and gesture arena as a finger. A replay is
/// driven from the frame clock: each frame dispatches the rows due by its
/// start, as the platform delivers input batched at the display refresh,
/// and timestamps are rebased so velocity tracking sees the recorded
/// intervals.
abstract final class PointerTape {
  static void Function(PointerDataPacket)? _forward;
  static List<TapeRow>? _recording;
  static TapeWindow? _recordingWindow;
  static String _recordingStart = '';
  static bool _replaying = false;

  /// Whether a replay runs.
  static bool get replaying => _replaying;

  /// Wraps the binding's pointer entry point and listens for Back. Call
  /// after the binding exists.
  static void install() {
    if (_forward != null) return;
    final dispatcher = PlatformDispatcher.instance;
    final forward = dispatcher.onPointerDataPacket;
    if (forward == null) return;
    _forward = forward;
    dispatcher.onPointerDataPacket = (packet) {
      if (_recording case final tape? when !_replaying) {
        for (final d in packet.data) {
          tape.add(PointerRow(_encode(d)));
        }
      }
      forward(packet);
    };
    WidgetsBinding.instance.addObserver(_BackRecorder());
  }

  static bool get recording => _recording != null;

  /// Starts a new recording in the window now, from the route [start],
  /// dropping one in progress.
  static void start(String start) {
    _recording = [];
    _recordingWindow = TapeWindow.now();
    _recordingStart = start;
  }

  /// Stops the recording and writes it to `<dir>/<name>.json`. Returns the
  /// row count.
  static Future<int> stop(String dir, String name) async {
    final rows = _recording;
    _recording = null;
    if (rows == null) return 0;
    final tape = Tape(_recordingWindow!, _recordingStart, rows);
    await File('$dir/$name.json').writeAsString(tape.encode());
    return rows.length;
  }

  /// Reads `<dir>/<name>.json`, refusing it when the window or the route
  /// on top ([route]) differs from the one it was recorded in.
  static Future<Tape> load(String dir, String name, String route) async {
    final file = File('$dir/$name.json');
    if (!file.existsSync()) throw TapeRefused('no tape at ${file.path}');
    final tape = Tape.decode(await file.readAsString());
    final now = TapeWindow.now();
    if (tape.window != now) {
      throw TapeRefused(
        'window is $now, the tape was recorded in '
        '${tape.window}',
      );
    }
    if (tape.start != route) {
      throw TapeRefused(
        'the app is at $route, the tape starts at '
        '${tape.start}',
      );
    }
    return tape;
  }

  /// Plays [tape] back. Completes after the last row with the row count.
  static Future<int> replay(Tape tape) async {
    final forward = _forward;
    if (forward == null) throw const TapeRefused('tape not installed');
    if (_replaying) throw const TapeRefused('a replay already runs');
    _replaying = true;
    try {
      return await play(tape.rows, forward: forward, back: _back);
    } finally {
      _replaying = false;
    }
  }

  /// The replay loop, on the frame clock: the first frame after the call
  /// is the tape's time zero, and each frame dispatches, before anything
  /// else of the frame runs, every row due by its vsync time, the pointer
  /// rows as one packet. An idle stretch of the tape waits on a timer and
  /// asks for no frames.
  @visibleForTesting
  static Future<int> play(
    List<TapeRow> tape, {
    required void Function(PointerDataPacket) forward,
    required void Function() back,
  }) async {
    final rows = [...tape]..sort((a, b) => a.time.compareTo(b.time));
    if (rows.isEmpty) return 0;
    final t0 = rows.first.time;
    final done = Completer<void>();
    const idle = Duration(milliseconds: 50);
    Duration? zero;
    var base = 0;
    var i = 0;
    void onFrame(Duration vsync) {
      var start = zero;
      if (start == null) {
        start = zero = vsync;
        base = Timeline.now;
        // The tape's time zero on the trace clock: the analysis places
        // every row from it.
        Timeline.timeSync('LABtape0', () {});
      }
      final now = (vsync - start).inMicroseconds;
      final shift = base - t0;
      final batch = <PointerData>[];
      while (i < rows.length && rows[i].time - t0 <= now) {
        switch (rows[i]) {
          case PointerRow(:final values):
            batch.add(_decode(values, shift));
          case BackRow():
            if (batch.isNotEmpty) {
              forward(PointerDataPacket(data: [...batch]));
              batch.clear();
            }
            back();
        }
        i++;
      }
      if (batch.isNotEmpty) forward(PointerDataPacket(data: batch));
      if (i >= rows.length) {
        done.complete();
        return;
      }
      final wait = rows[i].time - t0 - now;
      if (wait > idle.inMicroseconds) {
        Timer(
          Duration(microseconds: wait - 25000),
          () => SchedulerBinding.instance.scheduleFrameCallback(onFrame),
        );
      } else {
        SchedulerBinding.instance.scheduleFrameCallback(onFrame);
      }
    }

    SchedulerBinding.instance.scheduleFrameCallback(onFrame);
    await done.future;
    return rows.length;
  }

  /// Delivers Back as the platform does: `popRoute` on the navigation
  /// channel.
  static void _back() {
    const channel = SystemChannels.navigation;
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
  }

  static List<num> _encode(PointerData d) => [
    d.timeStamp.inMicroseconds,
    d.change.index,
    d.kind.index,
    d.signalKind?.index ?? 0,
    d.device,
    d.pointerIdentifier,
    d.physicalX,
    d.physicalY,
    d.physicalDeltaX,
    d.physicalDeltaY,
    d.buttons,
    d.pressure,
    d.pressureMax,
    d.size,
    d.radiusMajor,
    d.radiusMinor,
    d.scrollDeltaX,
    d.scrollDeltaY,
    d.embedderId,
    d.viewId,
    if (d.synthesized) 1 else 0,
  ];

  static PointerData _decode(List<num> e, int shiftMicros) => PointerData(
    timeStamp: Duration(microseconds: e[0].toInt() + shiftMicros),
    change: PointerChange.values[e[1].toInt()],
    kind: PointerDeviceKind.values[e[2].toInt()],
    signalKind: PointerSignalKind.values[e[3].toInt()],
    device: e[4].toInt(),
    pointerIdentifier: e[5].toInt(),
    physicalX: e[6].toDouble(),
    physicalY: e[7].toDouble(),
    physicalDeltaX: e[8].toDouble(),
    physicalDeltaY: e[9].toDouble(),
    buttons: e[10].toInt(),
    pressure: e[11].toDouble(),
    pressureMax: e[12].toDouble(),
    size: e[13].toDouble(),
    radiusMajor: e[14].toDouble(),
    radiusMinor: e[15].toDouble(),
    scrollDeltaX: e[16].toDouble(),
    scrollDeltaY: e[17].toDouble(),
    embedderId: e[18].toInt(),
    viewId: e[19].toInt(),
    synthesized: e[20] == 1,
  );
}

/// Notes a system Back in the recording. Registered before the app's own
/// observers, so it sees every `popRoute` first; it answers false, so the
/// navigators still run.
final class _BackRecorder with WidgetsBindingObserver {
  @override
  Future<bool> didPopRoute() async {
    if (PointerTape._recording case final tape? when !PointerTape._replaying) {
      tape.add(BackRow(Timeline.now));
    }
    return false;
  }
}
