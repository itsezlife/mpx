import 'dart:async';

import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';

/// A [TransferEnvelope] with no native part: it records what the engine
/// asked of it and sends the events a test gives it, so engine tests run on
/// any host.
final class FakeTransferEnvelope implements TransferEnvelope {
  final StreamController<TransferEnvelopeEvent> _events =
      StreamController.broadcast(sync: true);

  final List<TransferEnvelopeProgress> _starts = [];
  final List<TransferEnvelopeProgress> _updates = [];
  int _stops = 0;
  TransferEnvelopeProgress? _current;

  /// Every [start], oldest first.
  List<TransferEnvelopeProgress> get starts => List.unmodifiable(_starts);

  /// Every [update], oldest first.
  List<TransferEnvelopeProgress> get updates => List.unmodifiable(_updates);

  /// How many times the engine called [stop].
  int get stops => _stops;

  /// The progress of the envelope now: the last start or update, or null
  /// when none is started (never started, stopped, or ended by [emit] of
  /// a system end).
  TransferEnvelopeProgress? get current => _current;

  /// Whether an envelope is started.
  bool get isStarted => _current != null;

  @override
  void start(TransferEnvelopeProgress progress) {
    _starts.add(progress);
    _current = progress;
  }

  @override
  void update(TransferEnvelopeProgress progress) {
    _updates.add(progress);
    _current = progress;
  }

  @override
  void stop() {
    _stops++;
    _current = null;
  }

  @override
  Stream<TransferEnvelopeEvent> get events => _events.stream;

  /// Sends [event] as the native part would, synchronously. A system end
  /// also ends the envelope here.
  void emit(TransferEnvelopeEvent event) {
    if (event is TransferEnvelopeEvent$SystemEnded) _current = null;
    _events.add(event);
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();
}
