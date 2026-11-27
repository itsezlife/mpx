import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:l/l.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a [JournalRecord] came from: each source has its own policy, and
/// the journal holds them side by side so one log follows an item from the
/// host's call to the bytes on disk.
enum JournalSource {
  /// The mpx packages' `MpxDiagnostics`, the bytes cache's events (category
  /// `cache`) included.
  mpx,

  /// The example app's own log (`package:l`).
  app,
}

/// One diagnostics event as the journal keeps it: plain values only, so it
/// encodes to one JSON line and comes back after a restart unchanged.
///
/// Not an `MpxEvent`: the journal also holds the app's own log lines, and
/// the category and the operation are kept by name, which is all a restored
/// line needs.
@immutable
final class JournalRecord {
  /// A record; [fields] holds numbers, booleans and strings only.
  JournalRecord({
    required this.time,
    required this.level,
    required this.source,
    required this.category,
    required this.op,
    Map<String, String> ids = const {},
    Map<String, Object> fields = const {},
    this.message,
    this.error,
    this.stackTrace,
  }) : ids = Map.unmodifiable(ids),
       fields = Map.unmodifiable(fields);

  /// The record of an mpx package's [event].
  ///
  /// The error is kept as its text with every URL cut to its host: an error
  /// message is the one place a URL path or a query could slip into an event
  /// (an HTTP exception names its URI).
  factory JournalRecord.fromMpxEvent(MpxEvent event) => JournalRecord(
    time: event.time,
    level: event.level,
    source: JournalSource.mpx,
    category: event.category,
    op: event.op.name,
    ids: {for (final (name, id) in event.ids) name: id},
    fields: event.fields,
    error: switch (event.error) {
      final error? => withoutUrlPaths('$error'),
      null => null,
    },
    stackTrace: _trace(event.stackTrace),
  );

  /// The record of the app's own [log], category [appCategory].
  ///
  /// The message is the app's text, URLs cut to their host and the whole cut
  /// to [maxMessageLength].
  factory JournalRecord.fromLog(LogMessage log) => JournalRecord(
    time: log.timestamp,
    level: log.level.maybeWhen(
      shout: () => MpxEventLevel.error,
      error: () => MpxEventLevel.error,
      warning: () => MpxEventLevel.warning,
      info: () => MpxEventLevel.info,
      debug: () => MpxEventLevel.debug,
      orElse: () => MpxEventLevel.trace,
    ),
    source: JournalSource.app,
    category: appCategory,
    op: 'log',
    message: _clipMessage(withoutUrlPaths('${log.message}')),
    stackTrace: switch (log) {
      LogMessageError(:final stackTrace) => _trace(stackTrace),
      _ => null,
    },
  );

  /// Reads a record [toJson] wrote; null for a line that is not one (the
  /// torn last line of a process killed mid-write, a record of a newer
  /// format).
  static JournalRecord? tryParse(String line) {
    try {
      return switch (jsonDecode(line)) {
        {
              't': final int micros,
              'l': final String level,
              's': final String source,
              'c': final String category,
              'o': final String op,
            } &&
            final Map<String, Object?> json =>
          JournalRecord(
            time: DateTime.fromMicrosecondsSinceEpoch(micros),
            level: MpxEventLevel.values.byName(level),
            source: JournalSource.values.byName(source),
            category: category,
            op: op,
            ids: switch (json['ids']) {
              final Map<String, Object?> ids => {
                for (final MapEntry(:key, :value) in ids.entries)
                  if (value case final String id) key: id,
              },
              _ => const {},
            },
            fields: switch (json['f']) {
              final Map<String, Object?> fields => {
                for (final MapEntry(:key, :value) in fields.entries)
                  key: ?_plain(value),
              },
              _ => const {},
            },
            message: json['m'] as String?,
            error: json['e'] as String?,
            stackTrace: json['st'] as String?,
          ),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  /// The category name of [JournalSource.app] records.
  static const appCategory = 'app';

  /// The longest app message kept, in characters.
  static const maxMessageLength = 1000;

  /// When it happened.
  final DateTime time;

  /// How much it matters.
  final MpxEventLevel level;

  /// Which diagnostics it came from.
  final JournalSource source;

  /// The area, by name: an mpx category (`binding`, `cache`, `journal`) or
  /// [appCategory].
  final String category;

  /// What happened, by the operation's stable name.
  final String op;

  /// The correlation ids it carries, by name (`jobId`, `itemId`, `mediaKey`,
  /// `tag`).
  final Map<String, String> ids;

  /// Its facts: numbers, booleans and short strings.
  final Map<String, Object> fields;

  /// The text of an app log line; null for an mpx event.
  final String? message;

  /// The failure's text, URLs cut to their host.
  final String? error;

  /// Where the failure was thrown.
  final String? stackTrace;

  /// The record as one compact JSON object, the line the journal writes.
  Map<String, Object> toJson() => {
    't': time.microsecondsSinceEpoch,
    'l': level.name,
    's': source.name,
    'c': category,
    'o': op,
    if (ids.isNotEmpty) 'ids': ids,
    if (fields.isNotEmpty) 'f': fields,
    'm': ?message,
    'e': ?error,
    'st': ?stackTrace,
  };

  /// [toJson] encoded.
  String encode() => jsonEncode(toJson());

  /// [text] with every URL reduced to its scheme and host.
  ///
  /// Events end up in files users share; a URL's path, query and fragment
  /// can carry what the user sent or a token.
  static String withoutUrlPaths(String text) =>
      text.replaceAllMapped(_url, (match) => '${match[1]}://${match[2]}');

  static final _url = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*)://([^/\s?#]+)\S*');

  static Object? _plain(Object? value) => switch (value) {
    final num number => number,
    final bool flag => flag,
    final String text => text,
    _ => null,
  };

  static String _clipMessage(String text) => text.length <= maxMessageLength
      ? text
      : text.substring(0, maxMessageLength);

  static String? _trace(StackTrace? trace) => switch ('${trace ?? ''}'.trim()) {
    '' => null,
    final text => text,
  };

  @override
  String toString() =>
      'JournalRecord(${level.name} $category.$op, $ids, $fields)';
}
