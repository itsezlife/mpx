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
