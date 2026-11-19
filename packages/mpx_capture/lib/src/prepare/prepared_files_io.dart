import 'dart:io';

/// The size of the file at [path]; 0 when there is none.
Future<int> lengthOf(String path) async {
  final file = File(path);
  return file.existsSync() ? file.length() : 0;
}

/// Deletes the file at [path] when there is one.
void delete(String path) {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
}
