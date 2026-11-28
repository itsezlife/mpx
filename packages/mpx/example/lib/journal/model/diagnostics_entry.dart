import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:l/l.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a [DiagnosticsEntry] came from: each source has its own policy, and
/// the journal holds them side by side so one log follows an item from the
/// host's call to the bytes on disk.
enum DiagnosticsSource {
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
final class DiagnosticsEntry {
  /// A record; [fields] holds numbers, booleans and strings only.
  DiagnosticsEntry({
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
  factory DiagnosticsEntry.fromMpxEvent(MpxEvent event) => DiagnosticsEntry(
    time: event.time,
    level: event.level,
    source: DiagnosticsSource.mpx,
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
  factory DiagnosticsEntry.fromLog(LogMessage log) => DiagnosticsEntry(
    time: log.timestamp,
    level: log.level.maybeWhen(
      shout: () => MpxEventLevel.error,
      error: () => MpxEventLevel.error,
      warning: () => MpxEventLevel.warning,
      info: () => MpxEventLevel.info,
      debug: () => MpxEventLevel.debug,
      orElse: () => MpxEventLevel.trace,
    ),
    source: DiagnosticsSource.app,
    category: appCategory,
    op: 'log',
    message: _clipMessage(withoutUrlPaths('${log.message}')),
    stackTrace: switch (log) {
      LogMessageError(:final stackTrace) => _trace(stackTrace),
      _ => null,
    },
  );

  /// The entry's stored form (see [DiagnosticsEntryCodec]).
  static const codec = DiagnosticsEntryCodec();

  /// Reads an entry [encode] wrote; null for a line that is not one: the
  /// torn last line of a process killed mid-write, or an entry of another
  /// format. Both are [FormatException]s, the only failure a line read can
  /// have; anything else is a bug and is thrown.
  static DiagnosticsEntry? tryParse(String line) {
    try {
      return switch (jsonDecode(line)) {
        final Map<String, Object?> json => codec.decode(json),
        final other => throw FormatException(
          'Expected an object, found ${other.runtimeType}.',
          line,
        ),
      };
    } on FormatException {
      return null;
    }
  }

  /// The category name of [DiagnosticsSource.app] records.
  static const appCategory = 'app';

  /// The longest app message kept, in characters.
  static const maxMessageLength = 1000;

  /// When it happened.
  final DateTime time;

  /// How much it matters.
  final MpxEventLevel level;

  /// Which diagnostics it came from.
  final DiagnosticsSource source;

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

  /// The entry as one compact JSON line, the line the journal writes.
  String encode() => jsonEncode(codec.encode(this));

  /// [text] with every URL reduced to its scheme and host.
  ///
  /// Events end up in files users share; a URL's path, query and fragment
  /// can carry what the user sent or a token.
  static String withoutUrlPaths(String text) =>
      text.replaceAllMapped(_url, (match) => '${match[1]}://${match[2]}');

  static final _url = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*)://([^/\s?#]+)\S*');

  static String _clipMessage(String text) => text.length <= maxMessageLength
      ? text
      : text.substring(0, maxMessageLength);

  static String? _trace(StackTrace? trace) => switch ('${trace ?? ''}'.trim()) {
    '' => null,
    final text => text,
  };

  @override
  String toString() =>
      'DiagnosticsEntry(${level.name} $category.$op, $ids, $fields)';
}

/// A [DiagnosticsEntry] to and from the JSON object of its journal line.
///
/// ## Fields
///
/// | Key | Value | When |
/// |---|---|---|
/// | `t` | time, microseconds since the epoch | always |
/// | `l` | `MpxEventLevel` name | always |
/// | `s` | [DiagnosticsSource] name | always |
/// | `c` | category | always |
/// | `o` | operation | always |
/// | `ids` | object of string ids | when not empty |
/// | `f` | object of numbers, booleans and strings | when not empty |
/// | `m` | message | when set |
/// | `e` | error text | when set |
/// | `st` | stack trace | when set |
///
/// Keys are written in that order and an absent value is left out. A
/// missing required key, a value of the wrong type or an unknown name fails
/// with a [FormatException] naming the key, its source the object read.
final class DiagnosticsEntryCodec
    extends Codec<DiagnosticsEntry, Map<String, Object?>> {
  /// The codec.
  const DiagnosticsEntryCodec();

  @override
  Converter<DiagnosticsEntry, Map<String, Object?>> get encoder =>
      const _EntryEncoder();

  @override
  Converter<Map<String, Object?>, DiagnosticsEntry> get decoder =>
      const _EntryDecoder();
}

/// Keys of the journal line, shared by both directions.
abstract final class _Key {
  static const String time = 't';
  static const String level = 'l';
  static const String source = 's';
  static const String category = 'c';
  static const String op = 'o';
  static const String ids = 'ids';
  static const String fields = 'f';
  static const String message = 'm';
  static const String error = 'e';
  static const String stackTrace = 'st';
}

final class _EntryEncoder
    extends Converter<DiagnosticsEntry, Map<String, Object?>> {
  const _EntryEncoder();

  @override
  Map<String, Object?> convert(DiagnosticsEntry input) => {
    _Key.time: input.time.microsecondsSinceEpoch,
    _Key.level: input.level.name,
    _Key.source: input.source.name,
    _Key.category: input.category,
    _Key.op: input.op,
    if (input.ids.isNotEmpty) _Key.ids: input.ids,
    if (input.fields.isNotEmpty) _Key.fields: input.fields,
    _Key.message: ?input.message,
    _Key.error: ?input.error,
    _Key.stackTrace: ?input.stackTrace,
  };
}

final class _EntryDecoder
    extends Converter<Map<String, Object?>, DiagnosticsEntry> {
  const _EntryDecoder();

  @override
  DiagnosticsEntry convert(Map<String, Object?> input) {
    T required<T extends Object>(String key) => switch (input[key]) {
      final T value => value,
      null => throw FormatException('Missing "$key".', input),
      final other => throw FormatException(
        'Expected $T under "$key", found ${other.runtimeType}.',
        input,
      ),
    };
    T? optional<T extends Object>(String key) => switch (input[key]) {
      null => null,
      final T value => value,
      final other => throw FormatException(
        'Expected $T or null under "$key", found ${other.runtimeType}.',
        input,
      ),
    };
    T byName<T extends Enum>(List<T> values, String key) {
      final name = required<String>(key);
      for (final value in values) {
        if (value.name == name) return value;
      }
      throw FormatException('Unknown $key "$name".', input);
    }

    return DiagnosticsEntry(
      time: DateTime.fromMicrosecondsSinceEpoch(required<int>(_Key.time)),
      level: byName(MpxEventLevel.values, _Key.level),
      source: byName(DiagnosticsSource.values, _Key.source),
      category: required<String>(_Key.category),
      op: required<String>(_Key.op),
      ids: {
        for (final MapEntry(:key, :value)
            in (optional<Map<String, Object?>>(_Key.ids) ?? const {}).entries)
          key: switch (value) {
            final String id => id,
            _ => throw FormatException('Expected a string id "$key".', input),
          },
      },
      fields: {
        for (final MapEntry(:key, :value)
            in (optional<Map<String, Object?>>(_Key.fields) ?? const {})
                .entries)
          key: switch (value) {
            final num number => number,
            final bool flag => flag,
            final String text => text,
            _ => throw FormatException('Expected a plain field "$key".', input),
          },
      },
      message: optional<String>(_Key.message),
      error: optional<String>(_Key.error),
      stackTrace: optional<String>(_Key.stackTrace),
    );
  }
}
