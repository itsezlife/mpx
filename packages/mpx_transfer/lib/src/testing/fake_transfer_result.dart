import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/json_fields.dart';

/// What a scripted run completes with in a test: a stand-in for an
/// upload's remote reference or a download's cached file, named by [name].
///
/// The journal reads it back after a restart like any result kind.
@immutable
final class FakeTransferResult implements TransferResult {
  /// A result named [name].
  const FakeTransferResult(this.name);

  /// What tells two results apart.
  final String name;

  /// How the journal writes this kind; test support passes it to the
  /// engine.
  @internal
  static const TransferResultCodec codec = _FakeTransferResultCodec();

  @override
  bool operator ==(Object other) =>
      other is FakeTransferResult && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'FakeTransferResult($name)';
}

final class _FakeTransferResultCodec implements TransferResultCodec {
  const _FakeTransferResultCodec();

  @override
  String get kind => 'fake';

  @override
  Map<String, Object?>? encode(TransferResult result) => switch (result) {
    FakeTransferResult(:final name) => {'name': name},
    _ => null,
  };

  @override
  TransferResult decode(Map<String, Object?> json) =>
      FakeTransferResult(JsonFields(json).string('name'));
}
