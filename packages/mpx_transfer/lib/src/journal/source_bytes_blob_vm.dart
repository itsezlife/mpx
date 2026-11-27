import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// None on the VM, which has no `Blob`: an upload there reads a file.
SourceBytes $blobSourceBytes(Object blob) => throw UnsupportedError(
  'A Blob source is for the web; on the VM upload a file.',
);
