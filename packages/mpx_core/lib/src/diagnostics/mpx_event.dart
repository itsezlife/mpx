import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/identity/media_key.dart';

/// How much an [MpxEvent] matters, from the noisiest to the most severe.
///
/// The order is the threshold order: a policy enabled for [warning] is
/// enabled for [error] too.
enum MpxEventLevel {
  /// Per-part and per-batch detail: a part sent, a progress flush.
  trace,

  /// A stage change: a job queued, an item's stage moved on.
  debug,

  /// A milestone: a job finished, an envelope started.
  info,

  /// A degrade or a retry.
  warning,

  /// A failure that reaches a state.
  error,
}

/// What happened, as one value of an emitting package's closed operation
/// enum.
///
/// The core declares only this contract and its own `binding` operations:
/// each package keeps its own enum implementing it, so adding a path touches
/// that package alone. Implementing [Enum] keeps operations closed (only an
/// enum can implement this) and gives each a stable `name`, the one logs and
/// filters use. An operation is never a free-form message.
abstract interface class DiagnosticOp implements Enum {
  /// The area of mpx the operation belongs to, the same for every value of
  /// one enum: `binding`, `cache`, `journal`, `transport` and so on.
  String get category;
}

/// One structured diagnostics event an mpx package reports through
/// `MpxDiagnostics`.
///
/// Equal by value, so a test can compare whole events.
@immutable
final class MpxEvent {
  /// An event; [fields] is copied and checked in debug builds.
  MpxEvent({
    required this.time,
    required this.level,
    required this.op,
    this.jobId,
    this.itemId,
    this.mediaKey,
    this.tag,
    Map<String, Object> fields = const {},
    this.error,
    this.stackTrace,
  }) : assert(_fieldsProblem(fields) == null, _fieldsProblem(fields)),
       fields = Map.unmodifiable(fields);

  /// The longest string a field may hold: room for a reason, a code or a
  /// host, too short for a sentence of user text or a URL with a path.
  static const maxStringFieldLength = 64;

  /// [value] cut to [maxStringFieldLength] characters, for a string from
  /// outside the package (a type name, a platform code) that may run longer
  /// than a field holds, so an event never fails its own assert.
  static String clip(String value) => value.length <= maxStringFieldLength
      ? value
      : value.substring(0, maxStringFieldLength);

  /// When it happened.
  final DateTime time;

  /// How much it matters.
  final MpxEventLevel level;

  /// What happened; its [DiagnosticOp.category] is the event's [category].
  final DiagnosticOp op;

  /// The job it concerns: a transfer's id or a publish job's, as given.
  final String? jobId;

  /// The item of a job it concerns, the opaque id the host gave.
  final String? itemId;

  /// The media it concerns.
  final MediaKey? mediaKey;

  /// The host's job tag, carried as given. A host keeps its tags to ids.
  final String? tag;

  /// A few facts about it: sizes, counts, durations, attempts, reasons,
  /// codes.
  ///
  /// Values are numbers, booleans and strings of at most
  /// [maxStringFieldLength] characters; anything else (an enum, a nested map,
  /// a list) fails an assert, so every field exports as plain JSON. An enum
  /// goes in by its `name`.
  ///
  /// No user content, ever: no payload bytes, no file names or paths (an
  /// extension and a size instead), URLs as scheme and host only, no
  /// headers, no idempotency keys or resume tokens (a short hash when two
  /// must be compared). Events end up in files users export and share.
  final Map<String, Object> fields;

  /// The error of a failed path.
  final Object? error;

  /// Where [error] was thrown.
  final StackTrace? stackTrace;

  /// The area of mpx: the [op]'s category.
  String get category => op.category;

  /// The set correlation ids as `name=value` pairs, in a fixed order; a
  /// media key in its stable encoded form.
  Iterable<(String, String)> get ids sync* {
    if (jobId case final id?) yield ('jobId', id);
    if (itemId case final id?) yield ('itemId', id);
    if (mediaKey case final key?) yield ('mediaKey', key.encoded);
    if (tag case final id?) yield ('tag', id);
  }

  static String? _fieldsProblem(Map<String, Object> fields) {
    for (final MapEntry(:key, :value) in fields.entries) {
      switch (value) {
        case num() || bool():
          continue;
        case String(:final length) when length <= maxStringFieldLength:
          continue;
        case String(:final length):
          return 'Field "$key" is a string of $length characters; a field '
              'holds at most $maxStringFieldLength, so user content cannot '
              'slip into an event.';
        default:
          return 'Field "$key" is a ${value.runtimeType}; fields hold only '
              'numbers, booleans and short strings (an enum by its name).';
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MpxEvent ||
        other.time != time ||
        other.level != level ||
        other.op != op ||
        other.jobId != jobId ||
        other.itemId != itemId ||
        other.mediaKey != mediaKey ||
        other.tag != tag ||
        other.error != error ||
        other.stackTrace != stackTrace ||
        other.fields.length != fields.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      if (other.fields[key] != value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    time,
    level,
    op,
    jobId,
    itemId,
    mediaKey,
    tag,
    Object.hashAllUnordered(
      fields.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    error,
    stackTrace,
  );

  @override
  String toString() =>
      'MpxEvent(${level.name} $category.${op.name}'
      '${ids.map((id) => ' ${id.$1}=${id.$2}').join()}, fields: $fields'
      '${switch (error) {
        final error? => ', error: $error',
        null => '',
      }})';
}
