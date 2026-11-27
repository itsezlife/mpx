import 'dart:io';

import 'package:mpx_transfer/src/upload/upload_source_files.dart';

/// The file system's answer for an upload's source.
UploadSourceFiles? $platformUploadSourceFiles() => const _FileSystemSources();

final class _FileSystemSources implements UploadSourceFiles {
  const _FileSystemSources();

  @override
  Future<UploadSourceStat?> stat(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return UploadSourceStat(size: stat.size, modified: stat.modified);
  }
}
