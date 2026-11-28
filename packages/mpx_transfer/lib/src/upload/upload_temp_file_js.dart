/// On the web an upload reads the origin private file system, which the
/// web journal brings; until then in-memory bytes cannot become a source.
Future<String> $writeUploadTempFile(List<int> bytes, {String? directory}) =>
    throw UnsupportedError(
      'In-memory upload sources need the origin private file system.',
    );

/// None on the web, which writes no files of its own.
Future<void> $deleteUploadTempDirectory(String directory) async {}

/// None on the web, which writes no files of its own.
Future<List<String>> $uploadTempDirectories(String directory) async => const [];
