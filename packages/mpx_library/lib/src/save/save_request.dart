import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/save_item.dart';

/// One item of a `MediaSaver.saveContent` batch: a content by its [key],
/// with what to call and file it as.
///
/// The caller knows the name, the MIME type and the kind (from the content's
/// descriptor); the saver guesses none of them.
@immutable
final class SaveRequest {
  /// The content of [key], saved as [name].
  const SaveRequest(
    this.key, {
    required this.name,
    required this.mimeType,
    required this.kind,
    this.createdAt,
  });

  /// The content, as `TrackedTransfers` knows it.
  final MediaKey key;

  /// The file name the saved item gets (the platform may rename it on a
  /// collision).
  final String name;

  /// The MIME type of the content.
  final String mimeType;

  /// What the item is.
  final SaveItemKind kind;

  /// When the content was made, written where the platform keeps a date.
  final DateTime? createdAt;

  /// The item to save once [lease] lends the content's file.
  SaveItem leased(ContentFileLease lease) => SaveItem.leased(
    lease,
    name: name,
    mimeType: mimeType,
    kind: kind,
    createdAt: createdAt,
  );

  /// The item to save from [bytes], the content as a keeper that lends no
  /// file (the web) holds it.
  SaveItem inMemory(Uint8List bytes) => SaveItem.bytes(
    bytes,
    name: name,
    mimeType: mimeType,
    kind: kind,
    createdAt: createdAt,
  );

  // The name is user content: kept out of strings logs may hold.
  @override
  String toString() => 'SaveRequest($key, ${kind.name})';
}
