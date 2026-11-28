import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_request.dart';
import 'package:mpx_library/src/save/save_result.dart';

/// One `MediaSaver.save` batch on its way: one progress over every item, a
/// cancel, and a result per item.
abstract interface class SaveJob {
  /// A string unique to this job within the process; diagnostics events of
  /// the job carry it as their `jobId`.
  String get id;

  /// How far the batch is, from 0 to 1, never going back; 1 once [results]
  /// completes, however the items ended.
  ValueListenable<double> get progress;

  /// One result per item, in the batch's order, once every item is done.
  /// Never fails: an item that could not be saved is a
  /// [SaveResult.failed].
  Future<List<SaveResult>> get results;

  /// Stops the batch: an item not saved yet ends [SaveResult.cancelled], one
  /// already saved stays saved. Where the platform writes the batch in one
  /// block (Photos on Apple), a cancel before the block makes every item
  /// cancelled and a cancel during it has no effect. Idempotent; does
  /// nothing once [results] completed.
  void cancel();
}

/// Saves photos, videos and files out of the app: into the device's
/// gallery, the user's Downloads, or a place the user picks.
///
/// Implementations: `PlatformMediaSaver` (the platform adapters) and
/// `FakeMediaSaver` in `testing.dart`; all meet `MediaSaverContract`.
///
/// The saver knows no rights: a caller that has some (a chat that protects
/// its content) decides before it calls.
///
/// ## Contract
///
/// - One [save] call is one job, whatever the batch's size: one progress,
///   and on Apple one Photos change block, so one system prompt.
/// - Copies run off the UI isolate and stop on [SaveJob.cancel].
/// - A file lent by a keeper (`SaveItem.leased`) is copied, never moved,
///   and its lease is released once its item is done: saved, cancelled or
///   failed.
/// - A `SaveItemKind.file` item sent to the gallery is routed by its MIME
///   type: an image or a video goes to the gallery, anything else fails
///   `SaveFailure.unsupportedFormat`.
/// - A batch asks for the access its destination needs ([SaveAccess]) once,
///   before anything is written, when the user was not asked yet. Denied
///   access fails every item of the batch `SaveFailure.accessDenied`; a
///   build without the code for the destination, or a platform without an
///   adapter, fails every item `SaveFailure.unavailable`.
/// - [saveContent] makes each content local through `TrackedTransfers`
///   first; see there.
abstract interface class MediaSaver {
  /// Starts saving [items] to [destination] as one job.
  SaveJob save(List<SaveItem> items, SaveDestination destination);

  /// The access saving to [destination] has now, without asking: a host
  /// reads it to tell the user ahead (a denied access opens the system
  /// settings, not a prompt).
  Future<SaveAccess> access(SaveDestination destination);

  /// Shows the system prompt for the access of [destination] when the user
  /// was not asked yet, and answers the access after. [save] asks by
  /// itself, so a host calls this only to ask ahead of a save.
  Future<SaveAccess> requestAccess(SaveDestination destination);

  /// Starts saving the contents [requests] name to [destination] as one
  /// job, downloading those not local yet.
  ///
  /// Per request: a content not whole and local is downloaded as a tracked
  /// download the user started (`TrackedTransfers.download`, origin
  /// `user`), or joins the download another caller has under way; once it
  /// completes its file is leased (`TrackedTransfers.leaseFile`), saved as
  /// [save] saves a `SaveItem.leased`, and the lease is released when the
  /// item is done. Where the keeper lends no file (the web's browser
  /// storage) the content's bytes are read instead
  /// (`TrackedTransfers.readBytes`) and saved as a `SaveItem.bytes`. A
  /// completed download that can be neither leased nor read is downloaded
  /// once more, then fails `SaveFailure.unavailable`, as does a download
  /// that fails.
  ///
  /// One progress covers both stages: an item's download is 90 % of its
  /// share and its copy 10 %; an item already local counts its copy as its
  /// whole share. The batch is admitted (access) once, before any
  /// download: a refused access downloads nothing.
  ///
  /// [SaveJob.cancel] cancels the downloads this job started and leaves
  /// running those another caller started; their items end cancelled.
  ///
  /// Without `TrackedTransfers` in the saver's composition no content can be
  /// reached, and every item fails `SaveFailure.unavailable`.
  SaveJob saveContent(List<SaveRequest> requests, SaveDestination destination);
}
