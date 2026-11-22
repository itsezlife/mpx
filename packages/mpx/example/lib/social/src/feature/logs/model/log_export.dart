import 'dart:convert';

import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/util/log_level_label.dart';

/// Encodings of journal entries for leaving the app: a CSV file for
/// spreadsheets and scripts, and a plain-text block for the clipboard.
abstract final class LogExport {
  static const _columns = [
    'timestamp',
    'level',
    'message',
    'context',
    'stack_trace',
  ];
  static const _indent = '    ';

  /// Excel reads a CSV without a byte order mark as the system code page;
  /// other readers skip the mark.
  static const _bom = '﻿';

  /// RFC 4180 CSV of [newestFirst] (journal order), written oldest first:
  /// CRLF between records, line breaks kept inside quoted cells, context as a
  /// JSON object.
  static String csv(List<LogMessage> newestFirst) {
    final buffer = StringBuffer(_bom)..write(_row(_columns));
    for (final log in newestFirst.reversed) {
      buffer.write(
        _row([
          log.timestamp.logDateTime,
          log.level.tag,
          log.message.toString(),
          if (log.context.isEmpty)
            ''
          else
            jsonEncode(log.context, toEncodable: (value) => value.toString()),
          _stackTrace(log) ?? '',
        ]),
      );
    }
    return buffer.toString();
  }

  /// One entry as a console block: the header line, then indented message
  /// continuation lines, context, and stack frames.
  static String entryText(LogMessage log) {
    final [first, ...rest] = log.message.toString().split('\n');
    return [
      '${log.timestamp.logDateTime} ${log.level.tag} $first',
      for (final line in rest) '$_indent$line',
      for (final MapEntry(:key, :value) in log.context.entries)
        '$_indent$key: $value',
      if (_stackTrace(log) case final trace?)
        for (final frame in trace.split('\n'))
          if (frame.isNotEmpty) '$_indent$frame',
    ].join('\n');
  }

  /// File name stamped with [exportedAt]; sorts chronologically.
  static String fileName(DateTime exportedAt) {
    final t = exportedAt;
    return 'logs_${t._date}_${_pad2(t.hour)}-${_pad2(t.minute)}-'
        '${_pad2(t.second)}.csv';
  }

  static String? _stackTrace(LogMessage log) => switch (log) {
    LogMessageError(:final stackTrace)
        when stackTrace.toString().trim().isNotEmpty =>
      stackTrace.toString().trimRight(),
    _ => null,
  };

  static String _row(List<String> cells) => '${cells.map(_cell).join(',')}\r\n';

  /// Quotes a cell that holds a separator, quote, or line break. A cell that
  /// a spreadsheet would run as a formula gets a leading apostrophe: logs
  /// carry server text, and opening the file must not execute it.
  static String _cell(String value) {
    final text = value.startsWith(_formulaStart) ? "'$value" : value;
    if (!text.contains(_needsQuotes)) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  static final _formulaStart = RegExp('[=+\\-@\t\r]');
  static final _needsQuotes = RegExp('[",\r\n]');
}

/// Locale-free log timestamps: machine data, not prose.
extension LogTimestampFormat on DateTime {
  /// Wall-clock time with milliseconds, e.g. `20:54:20.622`.
  String get clockTime =>
      '${_pad2(hour)}:${_pad2(minute)}:${_pad2(second)}.'
      '${millisecond.toString().padLeft(3, '0')}';

  /// Date and [clockTime], e.g. `2026-10-07 20:54:20.622`.
  String get logDateTime => '$_date $clockTime';

  String get _date => '$year-${_pad2(month)}-${_pad2(day)}';
}

String _pad2(int n) => n.toString().padLeft(2, '0');
