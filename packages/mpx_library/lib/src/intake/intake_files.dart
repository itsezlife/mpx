import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/intake/file_intake.dart';
import 'package:mpx_library/src/intake/intake_kind.dart';

/// Intake files from plain fields: a path, or bytes with a MIME type.
///
/// A host whose text field already reads pasted media (bytes and a MIME
/// type, or a file path) hands it over through these, with no dependency
/// either way between the field and this package.
abstract final class IntakeFiles {
  /// The intake file of the local file at [path]; null when there is none.
  static Future<IntakeFile?> fromPath(String path, {String? mimeType}) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    final name = path.split(Platform.pathSeparator).last;
    return IntakeFile(
      source: IntakeSource.path(path),
      name: name,
      size: stat.size,
      mimeType: mimeType ?? IntakeKind.mimeOf(name),
      modified: stat.modified,
    );
  }

  /// Writes [bytes] of [mimeType] into a new file in [directory] (named
  /// [name], or after the time and the type) and answers its intake file.
  /// The write runs on the IO threads, not the UI isolate.
  static Future<IntakeFile> fromBytes(
    Uint8List bytes, {
    required String mimeType,
    required String directory,
    String? name,
  }) async {
    final fileName =
        name ??
        'pasted-${DateTime.now().microsecondsSinceEpoch}.${_extensionOf(mimeType)}';
    final file = File('$directory${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return IntakeFile(
      source: IntakeSource.path(file.path),
      name: fileName,
      size: bytes.length,
      mimeType: mimeType,
      modified: file.statSync().modified,
    );
  }

  static String _extensionOf(String mimeType) => switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/heic' => 'heic',
    'image/tiff' => 'tiff',
    'image/bmp' => 'bmp',
    'video/mp4' => 'mp4',
    'video/quicktime' => 'mov',
    _ => 'bin',
  };
}
