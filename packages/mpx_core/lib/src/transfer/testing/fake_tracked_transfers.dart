import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/transfer/content_file_lease.dart';
import 'package:mpx_core/src/transfer/tracked_transfers.dart';

/// A [TrackedTransfers] a test drives by hand: it records every call and
/// shows, per key, whatever [drive] last set.
///
/// It reacts as the seam's contract says and no further: [download] of a key
/// with no job under way reads [AssetTransfer.waiting], and [cancel] of a
/// download under way reads [AssetTransfer.awaitingUser] with its bytes.
/// Bytes never move by themselves; the test [drive]s them. A cancel of an
/// upload is only recorded, as its owner would decide.
final class FakeTrackedTransfers implements TrackedTransfers {
  final Map<MediaKey, _Watched> _values = {};
  final Map<MediaKey, String> _files = {};

  /// Every [download] call, oldest first.
  final List<({MediaKey key, TransferOrigin origin})> downloads = [];

  /// Every [cancel] call's key, oldest first.
  final List<MediaKey> cancels = [];

  /// Every [leaseFile] call's key, oldest first.
  final List<MediaKey> leaseRequests = [];

  /// Every lease handed out, oldest first.
  final List<ContentFileLease> leases = [];

  /// How many leases were handed out and not released yet.
  int get leasesHeld => leases.where((lease) => !lease.isReleased).length;

  _Watched _of(MediaKey key) =>
      _values.putIfAbsent(key, () => _Watched(AssetTransfer.none));

  /// What [key]'s watchers read now.
  AssetTransfer valueOf(MediaKey key) =>
      _values[key]?.value ?? AssetTransfer.none;

  /// Whether anyone listens to [key] now.
  bool isWatched(MediaKey key) => _values[key]?.watched ?? false;

  /// Sets what [key]'s watchers read, and tells them.
  void drive(MediaKey key, AssetTransfer value) => _of(key).value = value;

  /// Makes [key]'s content whole and local at [path]: [leaseFile] lends it
  /// from now on. Null takes it away.
  void setFile(MediaKey key, String? path) {
    if (path == null) {
      _files.remove(key);
    } else {
      _files[key] = path;
    }
  }

  @override
  void download(MediaKey key, {TransferOrigin origin = TransferOrigin.user}) {
    downloads.add((key: key, origin: origin));
    final notifier = _of(key);
    switch (notifier.value) {
      case AssetTransfer$None() ||
          AssetTransfer$AwaitingUser() ||
          AssetTransfer$Failed():
        notifier.value = AssetTransfer.waiting(notifier.value.total);
      default:
        break;
    }
  }

  @override
  ValueListenable<AssetTransfer> watch(MediaKey key) => _of(key);

  @override
  void cancel(MediaKey key) {
    cancels.add(key);
    final notifier = _values[key];
    if (notifier == null) return;
    switch (notifier.value) {
      case AssetTransfer$Waiting(:final total):
        notifier.value = AssetTransfer.awaitingUser(total);
      case AssetTransfer$Receiving(:final received, :final total):
        notifier.value = AssetTransfer.awaitingUser(total, received);
      default:
        break;
    }
  }

  @override
  Future<ContentFileLease?> leaseFile(MediaKey key) async {
    leaseRequests.add(key);
    final path = _files[key];
    if (path == null) return null;
    final lease = ContentFileLease(path: path, onRelease: () async {});
    leases.add(lease);
    return lease;
  }
}

// A notifier that tells whether it has listeners, which a ValueNotifier
// answers only to subclasses.
final class _Watched extends ValueNotifier<AssetTransfer> {
  _Watched(super.value);

  bool get watched => hasListeners;
}
