import 'dart:developer' as developer;

import 'package:mpx_core/src/diagnostics/mpx_event.dart';

/// `Timeline` sections for the hot paths of mpx (a part send, a journal
/// flush, a preparation), named `mpx.<category>.<op>`.
///
/// Off unless the build passes `--dart-define=mpx.trace=true`. [enabled] is
/// a compile-time constant, so in the default build each call is the body
/// alone and the section code is compiled out; unlike `MpxDiagnostics`, a
/// trace costs nothing to leave in.
abstract final class MpxTrace {
  /// Whether sections are recorded: the `mpx.trace` define.
  static const enabled = bool.fromEnvironment('mpx.trace');

  /// Runs [body] inside a synchronous section named after [op].
  static T sync<T>(DiagnosticOp op, T Function() body) {
    if (!enabled) return body();
    return developer.Timeline.timeSync(sectionName(op), body);
  }

  /// Runs [body] inside an asynchronous section named after [op], closed
  /// when its future completes, with a value or an error.
  static Future<T> async<T>(DiagnosticOp op, Future<T> Function() body) {
    if (!enabled) return body();
    final task = developer.TimelineTask()..start(sectionName(op));
    return body().whenComplete(task.finish);
  }

  /// The section name of [op]: `mpx.<category>.<op>`.
  static String sectionName(DiagnosticOp op) => 'mpx.${op.category}.${op.name}';
}
