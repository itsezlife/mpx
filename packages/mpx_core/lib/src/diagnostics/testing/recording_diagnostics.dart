import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/diagnostics/mpx_diagnostics.dart';
import 'package:mpx_core/src/diagnostics/mpx_event.dart';
import 'package:mpx_core/src/identity/media_key.dart';

/// A diagnostics policy that keeps every event, for tests of the events a
/// path emits.
///
/// Enabled at every level, so a test sees the events a host's journal would.
/// Install it with [RecordingDiagnostics.install], which puts the previous
/// policy back after the test.
final class RecordingDiagnostics extends MpxDiagnosticsOnEvent {
  /// A recorder holding no events.
  RecordingDiagnostics() : this._(<MpxEvent>[]);

  RecordingDiagnostics._(List<MpxEvent> events)
    : _events = events,
      super(events.add);

  /// Installs a new recorder as [MpxDiagnostics.current] for the running
  /// test and returns it.
  ///
  /// The previous policy comes back in the test's tear-down, which runs
  /// whether the test passed or failed; call it inside a test or a `setUp`.
  factory RecordingDiagnostics.install() {
    final previous = MpxDiagnostics.current;
    addTearDown(() => MpxDiagnostics.current = previous);
    return MpxDiagnostics.current = RecordingDiagnostics();
  }

  final List<MpxEvent> _events;

  /// Every event reported, oldest first.
  List<MpxEvent> get events => List.unmodifiable(_events);

  /// The events of [category], oldest first.
  List<MpxEvent> whereCategory(String category) => [
    for (final event in _events)
      if (event.category == category) event,
  ];

  /// The events of [op], oldest first.
  List<MpxEvent> whereOp(DiagnosticOp op) => [
    for (final event in _events)
      if (event.op == op) event,
  ];

  /// The events at [level], oldest first.
  List<MpxEvent> whereLevel(MpxEventLevel level) => [
    for (final event in _events)
      if (event.level == level) event,
  ];

  /// The events that carry every id given, oldest first.
  List<MpxEvent> whereIds({
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
    String? tag,
  }) => [
    for (final event in _events)
      if ((jobId == null || event.jobId == jobId) &&
          (itemId == null || event.itemId == itemId) &&
          (mediaKey == null || event.mediaKey == mediaKey) &&
          (tag == null || event.tag == tag))
        event,
  ];

  /// The `error` events, oldest first: a test of a failure path expects its
  /// one error event here, and a test of a path that should not fail expects
  /// none.
  List<MpxEvent> get errors => whereLevel(MpxEventLevel.error);

  /// Forgets the events recorded so far.
  void clear() => _events.clear();
}

/// Matches one [MpxEvent] by the parts given; a part left out matches
/// anything, and `time` is never compared.
///
/// Each part is a value or a matcher, so `fields: containsPair('attempt', 2)`
/// checks one field and `fields: {'attempt': 2}` all of them.
Matcher isMpxEvent({
  Object? level,
  Object? category,
  Object? op,
  Object? jobId,
  Object? itemId,
  Object? mediaKey,
  Object? tag,
  Object? fields,
  Object? error,
}) {
  var matcher = isA<MpxEvent>();
  if (level != null) {
    matcher = matcher.having((event) => event.level, 'level', level);
  }
  if (category != null) {
    matcher = matcher.having((event) => event.category, 'category', category);
  }
  if (op != null) {
    matcher = matcher.having((event) => event.op, 'op', op);
  }
  if (jobId != null) {
    matcher = matcher.having((event) => event.jobId, 'jobId', jobId);
  }
  if (itemId != null) {
    matcher = matcher.having((event) => event.itemId, 'itemId', itemId);
  }
  if (mediaKey != null) {
    matcher = matcher.having((event) => event.mediaKey, 'mediaKey', mediaKey);
  }
  if (tag != null) {
    matcher = matcher.having((event) => event.tag, 'tag', tag);
  }
  if (fields != null) {
    matcher = matcher.having((event) => event.fields, 'fields', fields);
  }
  if (error != null) {
    matcher = matcher.having((event) => event.error, 'error', error);
  }
  return matcher;
}
