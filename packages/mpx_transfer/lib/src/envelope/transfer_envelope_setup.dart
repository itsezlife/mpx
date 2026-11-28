import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';

/// The platform's OS envelope a facade runs `system` jobs in, with what it
/// shows: the two travel together, since an envelope without a [config]
/// starts nothing (`envelope` `degraded`, `why: unconfigured`).
@immutable
final class TransferEnvelopeSetup {
  /// [envelope], showing [config].
  const TransferEnvelopeSetup(this.envelope, {this.config});

  /// The platform's envelope.
  final TransferEnvelope envelope;

  /// The host's localised text and icon and its say over when the
  /// envelope starts; null for none, so no envelope starts.
  final TransferEnvelopeConfig? config;
}
