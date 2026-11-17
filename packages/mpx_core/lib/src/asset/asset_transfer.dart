import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';

/// The download of an entry's content as a surface shows it: nothing to
/// show, waiting for the first byte, receiving bytes, waiting for the user,
/// or failed.
///
/// One value per entry, shared by every binding of it, so a list cell, a
/// feed tile and a viewer page of the same content agree. Read it through
/// `AssetBinding.transfer`, which fills an unknown total from the content's
/// descriptor (`MediaDescriptor.byteSize`).
///
/// A failure is a transfer state, never a picture: the entry keeps the best
/// stage it reached, and a surface with a status control shows download,
/// which is the retry.
@immutable
sealed class AssetTransfer {
  const AssetTransfer();

  /// The content is known to be missing and is about to download; no byte
  /// has arrived. [total] is the size when known.
  const factory AssetTransfer.waiting([int? total]) = AssetTransfer$Waiting;

  /// [received] bytes of [total] (null when unknown) have arrived.
  const factory AssetTransfer.receiving(int received, [int? total]) =
      AssetTransfer$Receiving;

  /// The content is missing and does not download by itself: the host's
  /// auto-download policy said so, or the user cancelled it. A tap on the
  /// status control downloads it, from the [received] bytes a download that
  /// stopped short left (0 when none did).
  const factory AssetTransfer.awaitingUser([int? total, int received]) =
      AssetTransfer$AwaitingUser;

  /// The last download failed after [received] bytes of [total]; [kind]
  /// tells whether connectivity may fix it.
  const factory AssetTransfer.failed(
    AssetFailureKind kind, [
    int received,
    int? total,
  ]) = AssetTransfer$Failed;

  /// Nothing to show: the content is cached, final, or not yet asked for.
  static const AssetTransfer none = AssetTransfer$None._();

  /// The size of the content in bytes, or null when unknown.
  int? get total => null;

  /// How much has arrived, 0 to 1, or null when that is not known: no total,
  /// or a state that receives nothing.
  double? get fraction => null;

  /// Whether bytes are on their way or about to be: [AssetTransfer$Waiting]
  /// or [AssetTransfer$Receiving].
  bool get isActive => false;
}

/// [AssetTransfer.none].
final class AssetTransfer$None extends AssetTransfer {
  const AssetTransfer$None._();

  @override
  String toString() => 'AssetTransfer.none';
}

/// [AssetTransfer.waiting].
final class AssetTransfer$Waiting extends AssetTransfer {
  /// See [AssetTransfer.waiting].
  const AssetTransfer$Waiting([this.total]);

  @override
  final int? total;

  @override
  bool get isActive => true;

  @override
  bool operator ==(Object other) =>
      other is AssetTransfer$Waiting && other.total == total;

  @override
  int get hashCode => Object.hash(AssetTransfer$Waiting, total);

  @override
  String toString() => 'AssetTransfer.waiting($total)';
}

/// [AssetTransfer.receiving].
final class AssetTransfer$Receiving extends AssetTransfer {
  /// See [AssetTransfer.receiving].
  const AssetTransfer$Receiving(this.received, [this.total]);

  /// Bytes arrived so far.
  final int received;

  @override
  final int? total;

  @override
  double? get fraction => _fraction(received, total);

  @override
  bool get isActive => true;

  @override
  bool operator ==(Object other) =>
      other is AssetTransfer$Receiving &&
      other.received == received &&
      other.total == total;

  @override
  int get hashCode => Object.hash(AssetTransfer$Receiving, received, total);

  @override
  String toString() => 'AssetTransfer.receiving($received, $total)';
}

/// [AssetTransfer.awaitingUser].
final class AssetTransfer$AwaitingUser extends AssetTransfer {
  /// See [AssetTransfer.awaitingUser].
  const AssetTransfer$AwaitingUser([this.total, this.received = 0]);

  @override
  final int? total;

  /// The bytes a download that stopped short left; 0 when none did.
  final int received;

  @override
  bool operator ==(Object other) =>
      other is AssetTransfer$AwaitingUser &&
      other.total == total &&
      other.received == received;

  @override
  int get hashCode => Object.hash(AssetTransfer$AwaitingUser, total, received);

  @override
  String toString() => 'AssetTransfer.awaitingUser($total, $received)';
}

/// [AssetTransfer.failed].
final class AssetTransfer$Failed extends AssetTransfer {
  /// See [AssetTransfer.failed].
  const AssetTransfer$Failed(this.kind, [this.received = 0, this.total]);

  /// Whether connectivity may fix it.
  final AssetFailureKind kind;

  /// Bytes that had arrived when it failed.
  final int received;

  @override
  final int? total;

  @override
  double? get fraction => _fraction(received, total);

  @override
  bool operator ==(Object other) =>
      other is AssetTransfer$Failed &&
      other.kind == kind &&
      other.received == received &&
      other.total == total;

  @override
  int get hashCode => Object.hash(AssetTransfer$Failed, kind, received, total);

  @override
  String toString() => 'AssetTransfer.failed(${kind.name}, $received, $total)';
}

double? _fraction(int received, int? total) =>
    total == null || total <= 0 ? null : (received / total).clamp(0.0, 1.0);
