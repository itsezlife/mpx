import 'dart:collection' show Queue;

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:l/l.dart';

/// The last logs of the process, for the log journal to show.
///
/// Filled by a listener on `l`, set once at startup; the oldest log leaves
/// when the buffer is full.
class LogBuffer with ChangeNotifier {
  LogBuffer._internal();

  /// A buffer outside the process-wide [instance], so tests do not share it.
  @visibleForTesting
  LogBuffer.detached();

  static final LogBuffer _internalSingleton = LogBuffer._internal();

  static LogBuffer get instance => _internalSingleton;

  static const int bufferLimit = 5000;

  final Queue<LogMessage> _queue = Queue<LogMessage>();

  /// The logs, oldest first.
  Iterable<LogMessage> get logs => _queue;

  /// Drops every log.
  void clear() {
    _queue.clear();
    notifyListeners();
  }

  /// Adds [log], dropping the oldest when the buffer is full.
  void add(LogMessage log) {
    if (_queue.length >= bufferLimit) _queue.removeFirst();
    _queue.add(log);
    notifyListeners();
  }

  @override
  void dispose() {
    _queue.clear();
    super.dispose();
  }
}
