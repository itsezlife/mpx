import 'dart:js_interop';

import 'package:mpx_transfer/src/journal/journal_storage_opfs_js.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:web/web.dart' as web;

/// [blob], a browser `Blob` (a picked `File`), as an upload source.
SourceBytes $blobSourceBytes(Object blob) => switch (blob) {
  final JSAny js when js.isA<web.Blob>() => SourceBytes$Blob$JS(js as web.Blob),
  _ => throw ArgumentError.value(blob.runtimeType, 'blob', 'is not a Blob'),
};

/// None on the web, which has no file paths: a picked file is a `Blob`.
SourceBytes $fileSourceBytes(String path, int size) => throw UnsupportedError(
  'A file source is for the VM; on the web give the picked Blob.',
);
