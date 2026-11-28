import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/transfer/content_file_lease.dart';

/// Who started a tracked download, which sets whether it resumes by itself
/// after the app restarts.
enum TransferOrigin {
  /// The user asked (a tap on download, a save): the download resumes at the
  /// next start.
  user,

  /// The surface or the auto-download policy started it: after a restart it
  /// waits until a surface shows the content again.
  auto,
}

/// The seam through which content transfers become tracked jobs that outlive
/// a surface, and a process: a download a user can see or must keep, and an
/// upload whose source is a content the host shows.
///
/// Implemented by the transfer engine; taken by the asset cache
/// (`AssetCacheScope.tracked`) for the downloads of surfaces with a status
/// control, and by savers that need content local. The host wires it in its
/// composition root; without it, downloads are the cache's own and untracked.
///
/// Callers know no jobs, directions or publish jobs: one value per key,
/// [watch], says what a surface shows, whichever way the bytes go. The
/// implementation maps its job states onto it:
///
/// | Job | [watch] |
/// | --- | --- |
/// | Accepted, not started | `AssetTransfer.waiting` |
/// | Downloading | `AssetTransfer.receiving` |
/// | Uploading | `AssetTransfer.sending` |
/// | Paused by the system or for the network | the last `receiving` or `sending`, held |
/// | Paused by the user, or waiting to resume after a restart | `AssetTransfer.awaitingUser` |
/// | Failed | `AssetTransfer.failed` |
/// | Uploaded, not yet published | `AssetTransfer.sent` |
/// | Downloaded, or published | `AssetTransfer.none` |
///
/// The implementation reports each change of a watched key's value as
/// `BindingOp.mapped` (with the job's state and id), since only it knows the
/// job. `TrackedTransfersContract` (in `testing.dart`) holds every
/// implementation to this.
///
/// Single-threaded, on the UI isolate.
abstract interface class TrackedTransfers {
  /// Starts, or joins, the download of [key]'s content as a tracked job. One
  /// job per key: a second call while one is under way returns it, and a
  /// call for a download the user paused resumes it. [origin] sets whether
  /// the job resumes by itself after a restart; a [TransferOrigin.user] call
  /// for a job an auto origin started makes it the user's.
  void download(MediaKey key, {TransferOrigin origin = TransferOrigin.user});

  /// The transfer of [key]'s content, in either direction, as a surface shows
  /// it. [AssetTransfer.none] while no job has the key. The same listenable
  /// for every call with the key, for as long as anyone listens.
  ValueListenable<AssetTransfer> watch(MediaKey key);

  /// Cancels the transfer of [key]'s content. A download stops, keeps its
  /// bytes and reads [AssetTransfer.awaitingUser]; [download] resumes it. An
  /// upload's cancel goes to the job's owner, which decides what it means.
  /// Does nothing when no job has the key.
  void cancel(MediaKey key);

  /// Lends the local file of [key]'s whole content until the lease is
  /// released, or answers null when the content is not whole and local.
  Future<ContentFileLease?> leaseFile(MediaKey key);

  /// The bytes of [key]'s whole content, or null when it is not whole and
  /// local.
  ///
  /// For a keeper that holds content without files (the web's browser
  /// storage), where [leaseFile] lends none; a caller that can copy a file
  /// asks [leaseFile] first, since this holds the whole content in memory.
  Future<Uint8List?> readBytes(MediaKey key);
}
