import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// What a [SaveItem] is, which picks where the gallery keeps it.
enum SaveItemKind {
  /// A still image: the gallery's images.
  photo,

  /// A video: the gallery's videos.
  video,

  /// A GIF or a silent looping video. Apple saves it to Photos as an
  /// animated image, Android saves its `.gif` or mp4 to the gallery; on
  /// desktop and the web it saves as any file.
  animation,

  /// Any other file. Sent to the gallery it is routed by its MIME type: an
  /// image or a video goes to the gallery, anything else fails
  /// `SaveFailure.unsupportedFormat`.
  file,
}

/// One item of a `MediaSaver.save` batch: where its bytes are, and what to
/// call and file them as.
///
/// The bytes are a file at [path], either the host's own ([SaveItem.file])
/// or lent by a keeper such as the bytes cache ([SaveItem.leased]); or, where
/// there is no file system (the web) or the content only lives in memory,
/// [bytes] ([SaveItem.bytes]). Exactly one of [path] and [bytes] is set.
@immutable
final class SaveItem {
  /// A file the host owns at [path]. With [move] the saver may move it into
  /// place instead of copying it, consuming the source.
  const SaveItem.file(
    String this.path, {
    required this.name,
    required this.mimeType,
    required this.kind,
    this.createdAt,
    this.move = false,
  }) : lease = null,
       bytes = null;

  /// A file lent by its keeper (the bytes cache) through [lease]. The saver
  /// copies it, never moves it, and releases [lease] once the item is done:
  /// saved, cancelled or failed.
  ///
  /// [move] is accepted so a caller passing a host-owned flag through does
  /// not have to branch, but it is refused: a cache file is never moved.
  SaveItem.leased(
    ContentFileLease this.lease, {
    required this.name,
    required this.mimeType,
    required this.kind,
    this.createdAt,
    this.move = false,
  }) : path = lease.path,
       bytes = null;

  /// Content held in memory, for the web and for content with no file.
  const SaveItem.bytes(
    Uint8List this.bytes, {
    required this.name,
    required this.mimeType,
    required this.kind,
    this.createdAt,
  }) : path = null,
       lease = null,
       move = false;

  /// The file to save from; null for [SaveItem.bytes].
  final String? path;

  /// The lease that lends [path], released by the saver when the item is
  /// done; null for a host-owned file and for bytes.
  final ContentFileLease? lease;

  /// The content of a [SaveItem.bytes] item; null otherwise.
  final Uint8List? bytes;

  /// The file name the saved item gets (the platform may rename it on a
  /// collision).
  final String name;

  /// The MIME type of the content, as the caller knows it; the saver guesses
  /// nothing.
  final String mimeType;

  /// What the item is.
  final SaveItemKind kind;

  /// When the content was made, written where the platform keeps a date
  /// (Android `DATE_TAKEN`, the asset's creation date on Apple, the file
  /// modification time on desktop).
  final DateTime? createdAt;

  /// Whether the host lets the saver move the file instead of copying it.
  /// Honoured for [SaveItem.file] only.
  final bool move;

  /// Whether the file is lent by a keeper (a cache file), so it is never
  /// moved.
  bool get isLeased => lease != null;

  // Name and path are user content: they never go into a string a log may
  // keep.
  @override
  String toString() =>
      'SaveItem(${kind.name}, '
      '${path != null ? 'file' : 'bytes'}'
      '${isLeased ? ', leased' : ''}${move ? ', move' : ''})';
}
