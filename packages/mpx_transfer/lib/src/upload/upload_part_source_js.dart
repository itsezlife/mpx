import 'dart:js_interop';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/journal_storage_opfs_js.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';
import 'package:web/web.dart' as web;

/// The body of the part [offset]..[offset] + [length]: on the web a slice
/// of [bytes], the page's source or its copy in OPFS, handed to `fetch`.
/// [prefix] and [suffix] go around the slice. Without either the source is
/// lost, which no try again mends.
HttpBytesUploadBody $uploadPartBody(
  JournalSource source,
  SourceBytes? bytes, {
  required int offset,
  required int length,
  List<int> prefix = const [],
  List<int> suffix = const [],
}) => switch (bytes) {
  SourceBytes$Blob$JS(:final blob) => HttpBytesUploadBody.blob(
    blob,
    offset: offset,
    length: length,
    prefix: prefix,
    suffix: suffix,
  ),
  MemorySourceBytes(bytes: final data) => HttpBytesUploadBody.blob(
    web.Blob([data.toJS].toJS),
    offset: offset,
    length: length,
    prefix: prefix,
    suffix: suffix,
  ),
  _ => throw const UploadTransportException(
    'source_lost',
    kind: TransferFailureKind.sourceLost,
  ),
};
