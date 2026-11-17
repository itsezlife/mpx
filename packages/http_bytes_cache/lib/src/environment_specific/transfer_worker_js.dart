import 'package:http_bytes_cache/src/http/http_bytes_transfer.dart';
import 'package:http_bytes_cache/src/http/transfer_worker.dart';

/// Whether this platform runs transfers on a worker isolate: not on the web,
/// which has no isolate to give a socket to.
const bool $canTransfer = false;

/// Never called on the web ([$canTransfer] is false).
TransferWorker $transferWorker(HttpBytesTransfers config) =>
    throw UnsupportedError('There are no transfer workers on the web.');
