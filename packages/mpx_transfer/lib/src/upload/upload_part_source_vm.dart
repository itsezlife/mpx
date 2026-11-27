import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// The body of the part [offset]..[offset] + [length] of [source]: on the VM
/// the range of the file at its path, streamed by the transfer worker.
/// [bytes] is the web's; the VM reads the file.
HttpBytesUploadBody uploadPartBody(
  JournalSource source,
  SourceBytes? bytes, {
  required int offset,
  required int length,
}) => HttpBytesUploadBody.file(source.path, offset: offset, length: length);
