import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/util/log_buffer.dart';
import 'package:mpx_example/social/src/feature/logs/model/log_journal_snapshot.dart';

/// Projects a [LogBuffer] into the log journal.
///
/// A plain [ChangeNotifier], not a `control` `StateController`: the controller
/// observer logs every state change, the log lands in the buffer, and the
/// buffer would notify this controller again: an endless loop.
final class LogJournalController with ChangeNotifier {
  /// Starts projecting [buffer]; buffer changes are applied at most once per
  /// [refreshInterval].
  LogJournalController({
    required LogBuffer buffer,
    this.refreshInterval = const Duration(milliseconds: 250),
  }) : _buffer = buffer {
    _snapshot = LogJournalSnapshot.of(_buffer.logs, _filter);
    _$anchor = _buffer.logs.lastOrNull;
    _buffer.addListener(_onBufferChanged);
  }

  final LogBuffer _buffer;

  /// Longest delay between a buffer change and the journal showing it.
  final Duration refreshInterval;

  Timer? _$refresh;
  LogJournalFilter _filter = LogJournalFilter.all();
  LogJournalOrder _order = LogJournalOrder.newestFirst;
  late LogJournalSnapshot _snapshot;

  /// Newest buffered log when [_snapshot] was taken; logs after it are new.
  LogMessage? _$anchor;
  bool _paused = false;
  int _newCount = 0;

  /// What the journal shows now.
  LogJournalSnapshot get snapshot => _snapshot;

  /// Whether buffer changes are held back so the list stays still.
  bool get isPaused => _paused;

  /// Logs that arrived while paused and pass the filter.
  int get newCount => _newCount;

  /// Holds the list still; new logs only raise [newCount].
  void pause() => _paused = true;

  /// Shows everything that arrived while paused.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _refresh();
  }

  /// Time order of the list.
  LogJournalOrder get order => _order;

  /// Flips [order].
  void toggleOrder() {
    _order = _order.flipped;
    notifyListeners();
  }

  /// Active levels and search text.
  LogJournalFilter get filter => _filter;

  /// Turns [level] on or off.
  void toggleLevel(LogLevel level) => _setFilter(_filter.toggle(level));

  /// Shows only [level], or every level when it is already the only one.
  void soloLevel(LogLevel level) => _setFilter(_filter.solo(level));

  /// Filters by [query]; blank shows everything.
  void search(String query) {
    if (query == _filter.query) return;
    _setFilter(_filter.withQuery(query));
  }

  /// Drops every buffered log.
  void clear() {
    _buffer.clear();
    _refresh();
  }

  void _setFilter(LogJournalFilter filter) {
    _filter = filter;
    _refresh();
  }

  void _onBufferChanged() =>
      _$refresh ??= Timer(refreshInterval, _onRefreshDue);

  void _onRefreshDue() {
    _$refresh = null;
    if (!_paused) return _refresh();
    final count = _countNew();
    if (count == _newCount) return;
    _newCount = count;
    notifyListeners();
  }

  void _refresh() {
    _$refresh?.cancel();
    _$refresh = null;
    _snapshot = LogJournalSnapshot.of(_buffer.logs, _filter);
    _$anchor = _buffer.logs.lastOrNull;
    _newCount = 0;
    notifyListeners();
  }

  /// Walks back from the newest log to [_$anchor]. When the anchor was
  /// evicted or cleared, every buffered log counts as new.
  int _countNew() {
    final logs = _buffer.logs;
    var count = 0;
    for (var i = logs.length - 1; i >= 0; i--) {
      final log = logs.elementAt(i);
      if (identical(log, _$anchor)) break;
      if (_filter.accepts(log)) count++;
    }
    return count;
  }

  @override
  void dispose() {
    _buffer.removeListener(_onBufferChanged);
    _$refresh?.cancel();
    super.dispose();
  }
}
