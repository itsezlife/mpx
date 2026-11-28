import 'dart:async';

import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';

/// A [TransferEnvelope] with no native part: it records what the engine
/// asked of it and sends the events a test gives it, so engine tests run on
/// any host.
///
/// A start answers [TransferEnvelopeStart.started] under a new handle
/// (`fake-1`, `fake-2`, …) unless [refusal] is set, or
/// [holdStarts] keeps the answer until [answerStart]. [leftovers] are what
/// [live] reports, as envelopes an earlier process left.
final class FakeTransferEnvelope implements TransferEnvelope {
  /// An envelope whose platform rule is [startRule] (always by default, so
  /// any `system` job starts it), reporting [leftovers] as still live.
  FakeTransferEnvelope({
    this.startRule = TransferEnvelopeStartRule.always,
    Set<String> leftovers = const {},
    this.kind = TransferEnvelopeKind.uidt,
  }) : leftovers = {...leftovers};

  /// A config for tests: a title and nothing else.
  static const TransferEnvelopeConfig config = TransferEnvelopeConfig(
    title: 'Transfers',
  );

  @override
  final TransferEnvelopeStartRule startRule;

  /// The kind a start answers.
  final TransferEnvelopeKind kind;

  /// The handles [live] reports; a test may change them before a restart.
  final Set<String> leftovers;

  /// The code every start from now on refuses with; null (the default)
  /// lets them start.
  String? refusal;

  final StreamController<TransferEnvelopeEvent> _events =
      StreamController.broadcast(sync: true);

  final List<TransferEnvelopeProgress> _starts = [];
  final List<TransferEnvelopeProgress> _updates = [];
  final List<TransferEnvelopeConfig> _configs = [];
  final List<String> _adopted = [];
  int _stops = 0;
  int _handles = 0;
  TransferEnvelopeProgress? _current;
  String? _handle;
  bool _holding = false;
  Completer<TransferEnvelopeStart>? _held;

  /// Every [start], oldest first.
  List<TransferEnvelopeProgress> get starts => List.unmodifiable(_starts);

  /// Every [update], oldest first.
  List<TransferEnvelopeProgress> get updates => List.unmodifiable(_updates);

  /// The config of every [start] and [adopt], oldest first.
  List<TransferEnvelopeConfig> get configs => List.unmodifiable(_configs);

  /// The handles [adopt] took over, oldest first.
  List<String> get adopted => List.unmodifiable(_adopted);

  /// How many times the engine called [stop].
  int get stops => _stops;

  /// The progress of the envelope now: the last start or update, or null
  /// when none is started (never started, stopped, refused, or ended by
  /// [emit] of a system end or a cancel of every job).
  TransferEnvelopeProgress? get current => _current;

  /// The handle of the envelope started now, or null.
  String? get handle => _handle;

  /// Whether an envelope is started.
  bool get isStarted => _current != null;

  /// Keeps the answer of the next start until [answerStart].
  void holdStarts() => _holding = true;

  /// Answers the start [holdStarts] kept.
  void answerStart() {
    final held = _held;
    _held = null;
    _holding = false;
    held?.complete(_answer());
  }

  @override
  Future<Set<String>> live() async => {...leftovers};

  @override
  Future<TransferEnvelopeStart> start(
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) {
    _starts.add(progress);
    _configs.add(config);
    _current = progress;
    if (_holding) return (_held = Completer()).future;
    return Future.value(_answer());
  }

  TransferEnvelopeStart _answer() {
    if (refusal case final code?) {
      _current = null;
      return TransferEnvelopeStart.refused(code);
    }
    final handle = _handle = 'fake-${++_handles}';
    leftovers.add(handle);
    return TransferEnvelopeStart.started(handle, kind: kind);
  }

  @override
  void adopt(
    String handle,
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) {
    _adopted.add(handle);
    _configs.add(config);
    _handle = handle;
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
    _handle = null;
    leftovers.clear();
  }

  @override
  Stream<TransferEnvelopeEvent> get events => _events.stream;

  /// Sends [event] as the native part would, synchronously. A system end
  /// and a cancel of every job also end the envelope here.
  void emit(TransferEnvelopeEvent event) {
    if (event
        case TransferEnvelopeEvent$SystemEnded() ||
            TransferEnvelopeEvent$UserCancelledAll()) {
      _current = null;
      _handle = null;
      leftovers.clear();
    }
    _events.add(event);
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();
}
