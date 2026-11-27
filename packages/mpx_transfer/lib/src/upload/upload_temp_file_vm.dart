import 'dart:io';

/// Writes [bytes] to a new file in [directory] (the system temp directory
/// when omitted) and answers its path.
Future<String> $writeUploadTempFile(
  List<int> bytes, {
  String? directory,
}) async {
  final parent = directory == null
      ? Directory.systemTemp
      : await Directory(directory).create(recursive: true);
  final folder = await parent.createTemp('mpx_upload_');
  final file = File('${folder.path}${Platform.pathSeparator}source');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Deletes [directory] and everything in it; a directory that is not there
/// is already deleted.
Future<void> $deleteUploadTempDirectory(String directory) async {
  try {
    await Directory(directory).delete(recursive: true);
  } on PathNotFoundException {
    // Not there: already deleted.
  }
}

/// The names of the directories in [directory]; none when it is not there.
Future<List<String>> $uploadTempDirectories(String directory) async {
  try {
    return [
      await for (final entry in Directory(directory).list())
        if (entry is Directory)
          entry.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty),
    ];
  } on PathNotFoundException {
    return const [];
  }
}
