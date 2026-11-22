import 'package:l/l.dart';

/// Human-facing marks for a [LogLevel], shared by console output and the log
/// journal so both read the same.
extension LogLevelLabel on LogLevel {
  /// Glyph that leads a console line or a journal row.
  String get emoji => when(
    shout: () => '📣',
    v: () => '1️⃣',
    error: () => '❌',
    vv: () => '2️⃣',
    warning: () => '⚠️',
    vvv: () => '3️⃣',
    info: () => 'ℹ️',
    vvvv: () => '4️⃣',
    debug: () => '🔍',
    vvvvv: () => '5️⃣',
    vvvvvv: () => '6️⃣',
  );

  /// Upper-case tag: `ERROR`, `WARN`, `DEBUG`, or one `V` per verbosity step.
  String get tag => when(
    shout: () => 'SHOUT',
    v: () => 'V',
    error: () => 'ERROR',
    vv: () => 'VV',
    warning: () => 'WARN',
    vvv: () => 'VVV',
    info: () => 'INFO',
    vvvv: () => 'VVVV',
    debug: () => 'DEBUG',
    vvvvv: () => 'VVVVV',
    vvvvvv: () => 'VVVVVV',
  );
}
