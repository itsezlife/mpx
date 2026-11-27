import 'dart:io';

/// The VM hook: the operating system's version string, for the header of a
/// log export.
String? $operatingSystemVersion() => Platform.operatingSystemVersion;

/// The VM hook: what the device is, as far as the platform tells without a
/// plugin: the processor count (no model, no name: a name is the user's).
String? $deviceDescription() => '${Platform.numberOfProcessors} cores';

/// The VM hook: the folder named [name] in the platform's cache directory.
///
/// On Android [Directory.systemTemp] is the app's `code_cache`, which the
/// system empties on every app update, so the journal would lose the run
/// before the update; the `cache` directory beside it stays until the system
/// needs the space. A kill leaves either alone.
String $journalDirectoryPath(String name) {
  final temp = Directory.systemTemp;
  final base = Platform.isAndroid && temp.path.endsWith('/code_cache')
      ? '${temp.parent.path}/cache'
      : temp.path;
  return '$base/$name';
}
