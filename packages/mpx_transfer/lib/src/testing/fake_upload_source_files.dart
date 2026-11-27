import 'package:mpx_transfer/src/upload/upload_source_files.dart';

/// [UploadSourceFiles] with no file system: a test [put]s the files its
/// uploads read, then [touch]es, rewrites or [delete]s them between runs.
/// A path never put, or deleted, has no file.
final class FakeUploadSourceFiles implements UploadSourceFiles {
  /// A fake with no files; the first one put was written at [epoch].
  FakeUploadSourceFiles({DateTime? epoch})
    : _clock = epoch ?? DateTime.utc(2026);

  final Map<String, UploadSourceStat> _files = {};
  DateTime _clock;

  /// Every [stat] asked, oldest first.
  List<String> get asked => List.unmodifiable(_asked);
  final List<String> _asked = [];

  /// A file of [size] bytes at [path], written now (or at [modified]).
  void put(String path, {required int size, DateTime? modified}) =>
      _files[path] = UploadSourceStat(
        size: size,
        modified: modified ?? _tick(),
      );

  /// The file at [path] written again: a later time, and [size] when given.
  void touch(String path, {int? size}) {
    final file =
        _files[path] ?? (throw StateError('No file was put at $path.'));
    _files[path] = UploadSourceStat(size: size ?? file.size, modified: _tick());
  }

  /// No file at [path] any more.
  void delete(String path) => _files.remove(path);

  @override
  Future<UploadSourceStat?> stat(String path) async {
    _asked.add(path);
    return _files[path];
  }

  DateTime _tick() => _clock = _clock.add(const Duration(seconds: 1));
}
