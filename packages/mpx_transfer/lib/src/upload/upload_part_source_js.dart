import 'dart:js_interop';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/opfs_journal_storage.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';
import 'package:web/web.dart' as web;

/// The body of the part [offset]..[offset] + [length]: on the web a slice
/// of [bytes], the page's source or its copy in OPFS, handed to `fetch`.
/// Without either the source is lost, which no try again mends.
HttpBytesUploadBody uploadPartBody(
  JournalSource source,
  SourceBytes? bytes, {
  required int offset,
  required int length,
}) => switch (bytes) {
  BlobSourceBytes(:final blob) => HttpBytesUploadBody.blob(
    blob,
    offset: offset,
    length: length,
  ),
  MemorySourceBytes(bytes: final data) => HttpBytesUploadBody.blob(
    web.Blob([data.toJS].toJS),
    offset: offset,
    length: length,
  ),
  _ => throw const UploadTransportException(
    'source_lost',
    kind: TransferFailureKind.sourceLost,
  ),
};
