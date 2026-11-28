import 'dart:io';

/// The VM hook: the text of the file at [path], or null when there is none.
String? $readText(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// The VM hook: writes [text] to the file at [path].
void $writeText(String path, String text) => File(path)
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(text, flush: true);

/// The VM hook: kills this process at once, as the system or a force stop
/// would: no shutdown, nothing flushed that was not already.
void $killProcess() => Process.killPid(pid, ProcessSignal.sigkill);
