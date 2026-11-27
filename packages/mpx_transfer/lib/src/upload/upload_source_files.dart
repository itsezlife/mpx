import 'package:meta/meta.dart';

export 'upload_source_files_vm.dart'
    if (dart.library.js_interop) 'upload_source_files_js.dart';

/// Where the upload engine reads what an upload's source file is now, so a
/// restart tells an unchanged file from a changed or a missing one.
///
/// On the VM the engine reads the file system (`$platformUploadSourceFiles`);
/// on the web it reads none, because an upload there reads the page's own
/// source or the engine's copy in OPFS, which nothing else rewrites. Tests
/// give a fake.
abstract interface class UploadSourceFiles {
  /// The file at [path] now; null when no file is there.
  Future<UploadSourceStat?> stat(String path);
}

/// What an upload's source file is at one moment: its [size] and when it
/// was last [modified]. Two stats of the same file that differ in either
/// name different bytes.
@immutable
final class UploadSourceStat {
  /// A file of [size] bytes last changed at [modified].
  const UploadSourceStat({required this.size, required this.modified});

  /// The file's size in bytes.
  final int size;

  /// When the file was last written.
  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      other is UploadSourceStat &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(size, modified);

  @override
  String toString() => 'UploadSourceStat($size bytes, $modified)';
}
