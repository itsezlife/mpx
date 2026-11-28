import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
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
/// - Denied access fails every item of the batch
///   `SaveFailure.accessDenied`; a platform without an adapter fails every
///   item `SaveFailure.unavailable`.
abstract interface class MediaSaver {
  /// Starts saving [items] to [destination] as one job.
  SaveJob save(List<SaveItem> items, SaveDestination destination);
}
