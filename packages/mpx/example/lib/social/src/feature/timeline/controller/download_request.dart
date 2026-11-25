import 'package:mpx_core/mpx_core.dart';

/// Whether the reader asked for a clip that waited for them: it was
/// `awaitingUser` (the auto-download policy held it back) and is now being
/// fetched. Such a clip plays as it streams in; the feed
/// does the same once this says so, instead of waiting for the whole file.
///
/// Fed every transfer of the clip's content, in order. A clip the policy
/// fetches by itself (a prefix, a small file) never waited, so it never
/// counts: the policy's own limits already say what plays.
final class DownloadRequest {
  bool _waited = false;
  bool _asked = false;

  /// Whether the reader has asked, since the clip waited.
  bool get asked => _asked;

  /// Takes the next [transfer] of the content; returns whether the reader has
  /// asked now.
  bool see(AssetTransfer transfer) {
    switch (transfer) {
      case AssetTransfer$AwaitingUser():
        _waited = true;
        _asked = false;
      case AssetTransfer$Waiting() || AssetTransfer$Receiving():
        if (_waited) _asked = true;
      default:
        break;
    }
    return _asked;
  }
}
