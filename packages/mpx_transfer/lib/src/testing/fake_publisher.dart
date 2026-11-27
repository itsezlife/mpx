import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:mpx_transfer/src/publish/publisher.dart';

/// A [Publisher] with no remote end, for tests of publish jobs: it records
/// every call and answers each one from a script.
///
/// Each call takes the next scripted answer ([answerWith], [throwOnNext]);
/// with none scripted it answers `published` with no result. With [hold]
/// set, a call waits until the test answers it ([answer], [fail]), which
/// lets a test kill the engine while a publish is under way.
final class FakePublisher implements Publisher {
  /// A publisher that answers at once unless [hold] is set.
  FakePublisher({this.hold = false});

  /// Whether a call waits for [answer] or [fail].
  bool hold;

  final List<FakePublishCall> _calls = [];
  final Queue<FutureOr<PublishOutcome> Function()> _script = Queue();

  /// Every call so far, in order.
  List<FakePublishCall> get calls => List.unmodifiable(_calls);

  /// The calls still waiting for an answer.
  List<FakePublishCall> get pending => [
    for (final call in _calls)
      if (!call.isAnswered) call,
  ];

  /// The next call answers [outcome].
  void answerWith(PublishOutcome outcome) => _script.add(() => outcome);

  /// The next call throws [error].
  void throwOnNext(Object error) =>
      _script.add(() => Error.throwWithStackTrace(error, StackTrace.current));

  /// Answers the oldest waiting call with [outcome] (`published` with no
  /// result when omitted).
  void answer([PublishOutcome? outcome]) =>
      _oldest()._answer(outcome ?? PublishOutcome.published());

  /// Fails the oldest waiting call with [error].
  void fail(Object error) => _oldest()._fail(error);

  @override
  Future<PublishOutcome> publish(
    Uint8List payload,
    Map<String, PublishItemRefs> items,
    String idempotencyKey,
  ) {
    final call = FakePublishCall._(payload, items, idempotencyKey);
    _calls.add(call);
    if (_script.isNotEmpty) {
      final next = _script.removeFirst();
      unawaited(Future.sync(next).then(call._answer, onError: call._fail));
    } else if (!hold) {
      call._answer(PublishOutcome.published());
    }
    return call._outcome.future;
  }

  FakePublishCall _oldest() {
    for (final call in _calls) {
      if (!call.isAnswered) return call;
    }
    throw StateError('No publish call is waiting.');
  }
}

/// One call a [FakePublisher] received.
final class FakePublishCall {
  FakePublishCall._(Uint8List payload, this.items, this.idempotencyKey)
    : payload = Uint8List.fromList(payload);

  /// The payload the job carried.
  final Uint8List payload;

  /// Each item's id to its references, in the job's order.
  final Map<String, PublishItemRefs> items;

  /// The job's idempotency key.
  final String idempotencyKey;

  final Completer<PublishOutcome> _outcome = Completer();

  /// Whether the call was answered.
  bool get isAnswered => _outcome.isCompleted;

  void _answer(PublishOutcome outcome) {
    if (!isAnswered) _outcome.complete(outcome);
  }

  void _fail(Object error) {
    if (!isAnswered) _outcome.completeError(error);
  }

  @override
  String toString() => 'FakePublishCall(${items.length} items)';
}
