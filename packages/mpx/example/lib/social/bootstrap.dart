import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/util/log_buffer.dart';
import 'package:mpx_example/social/src/common/util/log_level_label.dart';
import 'package:mpx_example/social/src/feature/initialization/app_error.dart';
import 'package:mpx_example/social/src/feature/initialization/initialization.dart';

/// Starts the social feed: initializes it step by step and runs it, or
/// shows why it could not start.
Future<void> bootstrap() async {
  // Buffered in every build mode, for the log journal.
  l.listen(_bufferLog);

  await l.capture(
    () => runZonedGuarded(() async {
      try {
        await $initializeApp();
      } on Object catch (error, stackTrace) {
        l.e('Initialization failed: $error', stackTrace);
        runApp(AppError(error: error, stackTrace: stackTrace));
      }
    }, (error, stackTrace) => l.e('Uncaught error: $error', stackTrace)),
    const LogOptions(
      overrideOutput: _messageFormatting,
      outputInRelease: true,
      printColors: false,
      // `--dart-define=LOG_TO_PRINT=true` sends the logs to the console, for
      // a run from the command line.
      output: bool.fromEnvironment('LOG_TO_PRINT')
          ? LogOutput.print
          : LogOutput.developer,
    ),
  );
}

/// Adds the log to the buffer the journal shows.
void _bufferLog(LogMessage log) => LogBuffer.instance.add(log);

/// Formats the log message: level glyph, time, message, stack trace.
String? _messageFormatting(LogMessage log) {
  final time =
      '${log.timestamp.hour}:${log.timestamp.minute.toString().padLeft(2, '0')}';
  final message = '[${log.level.emoji}] $time | ${log.message}';
  final stackTrace = switch (log) {
    LogMessageError(:final stackTrace) =>
      '\n${stackTrace.toString().split('\n').map((line) => '  $line').join('\n')}',
    _ => '',
  };
  return '$message$stackTrace';
}
