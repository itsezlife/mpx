import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/diagnostics/mpx_event.dart';
import 'package:mpx_core/src/identity/media_key.dart';

/// Where [MpxDiagnostics.developer] writes a line: `dart:developer`'s `log`
/// unless a test passes its own.
typedef MpxDeveloperLog =
    void Function(
      String message, {
      required String name,
      required int level,
      Object? error,
      StackTrace? stackTrace,
      DateTime? time,
    });

/// Where mpx packages' diagnostics events go: nowhere, the developer log, or
/// the host.
///
/// One policy per process, [current], set once by the host at start;
/// packages read it at the call site and take no diagnostics parameter, so
/// no constructor threads it through and none can forget it. A test that
/// changes it restores it (`RecordingDiagnostics.install` in `testing.dart`
/// does), since a package's tests share one process.
///
/// A call site reports through [emit], which checks [isEnabled] before it
/// builds the event's fields, so the silent default costs one check:
///
/// ```dart
/// MpxDiagnostics.current.emit(
///   MpxEventLevel.debug,
///   BindingOp.trackedDownload,
///   mediaKey: key,
///   fields: () => {'origin': origin.name},
/// );
/// ```
@immutable
sealed class MpxDiagnostics {
  const MpxDiagnostics();

  /// Reports nothing (the default).
  const factory MpxDiagnostics.silent() = MpxDiagnosticsSilent;

  /// Writes every event to the `dart:developer` log under the name `mpx`,
  /// each line led by `<category>.<op>`.
  ///
  /// [log] stands in for `dart:developer`'s `log` in tests.
  const factory MpxDiagnostics.developer({
    @visibleForTesting MpxDeveloperLog log,
  }) = MpxDiagnosticsDeveloper;

  /// Hands every event at [minLevel] or above to the host's [onEvent], which
  /// routes it (a journal, a crash reporter keeping warnings and errors in
  /// release builds).
  ///
  /// [onEvent] must not throw; a throw is swallowed so diagnostics never
  /// fail the path they describe.
  const factory MpxDiagnostics.onEvent(
    void Function(MpxEvent event) onEvent, {
    MpxEventLevel minLevel,
  }) = MpxDiagnosticsOnEvent;

  /// The process-wide policy; silent until the host sets one.
  static MpxDiagnostics current = const MpxDiagnostics.silent();

  /// Whether an event at [level] goes anywhere.
  ///
  /// A call site that builds more than [emit]'s field builder covers (an id
  /// from a lookup, say) checks this first.
  bool isEnabled(MpxEventLevel level);

  /// Sends [event] where this policy routes it, if its level is enabled.
  ///
  /// Never throws: a sink that throws is ignored, so a report inside a
  /// failure path (a `catchError`, an unawaited future) cannot raise a second,
  /// unhandled error over the first. Debug builds write the sink's failure
  /// to the `dart:developer` log (`mpx.diagnostics`), so a broken sink is
  /// seen during development; release builds drop it.
  void report(MpxEvent event) {
    if (!isEnabled(event.level)) return;
    try {
      _deliver(event);
    } on Object catch (error, stackTrace) {
      // Not an assert: it would throw inside the failure path the event
      // describes, the second error this method exists to prevent. The log
      // is the sink of last resort.
      assert(() {
        developer.log(
          'A diagnostics sink threw on ${event.category}.${event.op.name}',
          name: 'mpx.diagnostics',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
        return true;
      }(), 'unreachable');
    }
  }

  /// Reports an event stamped now, building [fields] only when [level] is
  /// enabled.
  void emit(
    MpxEventLevel level,
    DiagnosticOp op, {
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
    String? tag,
    Map<String, Object> Function()? fields,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!isEnabled(level)) return;
    report(
      MpxEvent(
        time: DateTime.now(),
        level: level,
        op: op,
        jobId: jobId,
        itemId: itemId,
        mediaKey: mediaKey,
        tag: tag,
        fields: fields?.call() ?? const {},
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  void _deliver(MpxEvent event);
}

/// [MpxDiagnostics.silent].
final class MpxDiagnosticsSilent extends MpxDiagnostics {
  /// The silent policy.
  const MpxDiagnosticsSilent();

  @override
  bool isEnabled(MpxEventLevel level) => false;

  @override
  void _deliver(MpxEvent event) {}
}

/// [MpxDiagnostics.developer].
final class MpxDiagnosticsDeveloper extends MpxDiagnostics {
  /// The developer-log policy.
  const MpxDiagnosticsDeveloper({this.log = developer.log});

  /// Where lines go.
  final MpxDeveloperLog log;

  @override
  bool isEnabled(MpxEventLevel level) => true;

  @override
  void _deliver(MpxEvent event) {
    final message = StringBuffer('${event.category}.${event.op.name}');
    for (final (name, id) in event.ids) {
      message.write(' $name=$id');
    }
    for (final MapEntry(:key, :value) in event.fields.entries) {
      message.write(' $key=$value');
    }
    log(
      message.toString(),
      name: 'mpx',
      // The `package:logging` values the developer tools read.
      level: switch (event.level) {
        MpxEventLevel.trace => 300,
        MpxEventLevel.debug => 500,
        MpxEventLevel.info => 800,
        MpxEventLevel.warning => 900,
        MpxEventLevel.error => 1000,
      },
      error: event.error,
      stackTrace: event.stackTrace,
      time: event.time,
    );
  }
}

/// [MpxDiagnostics.onEvent].
///
/// Open to extension so the recorder in `testing.dart` can be one.
base class MpxDiagnosticsOnEvent extends MpxDiagnostics {
  /// Forwards every event at [minLevel] or above to [onEvent].
  const MpxDiagnosticsOnEvent(
    this.onEvent, {
    this.minLevel = MpxEventLevel.trace,
  });

  /// The host's callback.
  final void Function(MpxEvent event) onEvent;

  /// The lowest level forwarded.
  final MpxEventLevel minLevel;

  @override
  bool isEnabled(MpxEventLevel level) => level.index >= minLevel.index;

  @override
  void _deliver(MpxEvent event) => onEvent(event);
}
