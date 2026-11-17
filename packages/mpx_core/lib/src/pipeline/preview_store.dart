import 'dart:typed_data';

import 'package:mpx_core/src/identity/media_key.dart';

/// Where the pipeline keeps the previews it derived, so content whose
/// descriptor carries none starts at `AssetStage.preview` on every later
/// show, after a restart too.
///
/// A derived preview is the content's first drawable frame scaled to at most
/// 40 px on its long edge, PNG-encoded and unblurred: the pipeline blurs it
/// at decode, with the stack's `PreviewBlur`, so a stored preview follows
/// the platform style. A store holds a few KB per content and may forget any
/// of them (a quota, eviction); a missing preview only means the content
/// shows without one until it is derived again.
abstract interface class PreviewStore {
  /// The preview of [key] from memory, without IO, or null when it is not
  /// in memory (it may still be on disk: [read]).
  Uint8List? peek(MediaKey key);

  /// The preview of [key], from memory or disk, or null when there is none.
  /// Never throws: a store that cannot read answers null.
  Future<Uint8List?> read(MediaKey key);

  /// Keeps [png] as the preview of [key]. Returns at once: the store writes
  /// when it can, and [peek] answers it from then on.
  void write(MediaKey key, Uint8List png);
}
