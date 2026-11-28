import 'dart:io';
import 'dart:typed_data';

import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// None on the VM, which has no `Blob`: an upload there reads a file.
SourceBytes $blobSourceBytes(Object blob) => throw UnsupportedError(
  'A Blob source is for the web; on the VM upload a file.',
);

/// The file at [path] as an upload source: what an upload on the VM reads
/// as it is, with no copy.
SourceBytes $fileSourceBytes(String path, int size) =>
    SourceBytes$File$VM(path, size);

/// A file on the VM as [SourceBytes]: the engine uploads it from [path].
final class SourceBytes$File$VM implements SourceBytes$File {
  /// The file at [path], [size] bytes long.
  SourceBytes$File$VM(this.path, this.size);

  @override
  final String path;

  @override
  final int size;

  @override
  Future<Uint8List> read([int start = 0, int? end]) async {
    final file = await File(path).open();
    try {
      await file.setPosition(start);
      return await file.read((end ?? size) - start);
    } finally {
      await file.close();
    }
  }
}
