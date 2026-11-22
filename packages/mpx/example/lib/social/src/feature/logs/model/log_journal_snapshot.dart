import 'package:flutter/foundation.dart';
import 'package:l/l.dart';

/// Time order of the journal list.
enum LogJournalOrder {
  /// Newest log on top; new logs arrive at the top.
  newestFirst,

  /// Oldest log on top; new logs arrive at the bottom, as in a console.
  oldestFirst;

  /// The opposite order.
  LogJournalOrder get flipped => switch (this) {
    newestFirst => oldestFirst,
    oldestFirst => newestFirst,
  };
}

/// Which logs the journal shows: enabled [levels] and a free-text [query].
@immutable
final class LogJournalFilter {
  /// Creates a filter.
  LogJournalFilter({required this.levels, this.query = ''})
    : _needle = query.trim().toLowerCase();

  /// Shows every level, no query.
  factory LogJournalFilter.all() =>
      LogJournalFilter(levels: LogLevel.values.toSet());

  /// Levels that pass.
  final Set<LogLevel> levels;

  /// Search text as typed. Blank matches everything.
  final String query;

  final String _needle;

  /// Whether [log] passes both the level set and the query.
  bool accepts(LogMessage log) =>
      levels.contains(log.level) && matchesQuery(log);

  /// Whether [log] contains the query in its message, context, or stack
  /// trace, ignoring case. Level-agnostic, so level badges can count query
  /// hits.
  bool matchesQuery(LogMessage log) {
    if (_needle.isEmpty) return true;
    bool has(Object? value) => value.toString().toLowerCase().contains(_needle);
    return has(log.message) ||
        log.context.entries.any((e) => has(e.key) || has(e.value)) ||
        switch (log) {
          LogMessageError(:final stackTrace) => has(stackTrace),
          LogMessageVerbose() => false,
        };
  }

  /// Turns [level] off when it is on, on when it is off.
  LogJournalFilter toggle(LogLevel level) => LogJournalFilter(
    levels: levels.contains(level)
        ? ({...levels}..remove(level))
        : {...levels, level},
    query: query,
  );

  /// Keeps only [level]; when [level] is already the only one, turns every
  /// level back on.
  LogJournalFilter solo(LogLevel level) => LogJournalFilter(
    levels: levels.length == 1 && levels.contains(level)
        ? LogLevel.values.toSet()
        : {level},
    query: query,
  );

  /// Replaces the search text.
  LogJournalFilter withQuery(String query) =>
      LogJournalFilter(levels: levels, query: query);
}

/// The journal's view of a log sequence under a [LogJournalFilter].
@immutable
final class LogJournalSnapshot {
  const LogJournalSnapshot._({
    required this.visible,
    required this.total,
    required Map<LogLevel, int> countByLevel,
  }) : _countByLevel = countByLevel;

  /// Projects [logs] (oldest first, as buffered) through [filter].
  factory LogJournalSnapshot.of(
    Iterable<LogMessage> logs,
    LogJournalFilter filter,
  ) {
    final visible = <LogMessage>[];
    final countByLevel = <LogLevel, int>{};
    var total = 0;
    for (final log in logs) {
      total++;
      if (!filter.matchesQuery(log)) continue;
      countByLevel.update(log.level, (n) => n + 1, ifAbsent: () => 1);
      if (filter.levels.contains(log.level)) visible.add(log);
    }
    return LogJournalSnapshot._(
      visible: List.unmodifiable(visible.reversed),
      total: total,
      countByLevel: Map.unmodifiable(countByLevel),
    );
  }

  /// Logs that pass the filter, newest first.
  final List<LogMessage> visible;

  /// Number of logs before filtering.
  final int total;

  final Map<LogLevel, int> _countByLevel;

  /// Logs of [level] that match the query, whether or not [level] is on.
  int countOf(LogLevel level) => _countByLevel[level] ?? 0;
}
