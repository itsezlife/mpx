import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

int _fakePartSize(int size) => FakeUploadTransport.defaultPartSize;

/// An [UploadTransport] with no remote end: a test scripts what each call
/// answers (acknowledgements, failures, resume) and reads what the engine
/// sent.
///
/// It keeps its state across sessions, as a server would: a session opened
/// with a token it issued continues ([UploadSession.resumed]) while
/// [acceptsResume] holds. With [holdParts], each part waits until the test
/// [ack]s or [reject]s it, so a test can hold parts in flight and answer
/// them in any order; otherwise each part is acknowledged at once.
final class FakeUploadTransport implements UploadTransport {
  /// A fake named [id] declaring [capabilities] ([defaultCapabilities]
  /// unless given).
  FakeUploadTransport({
    this.id = 'fake',
    UploadCapabilities? capabilities,
    this.acceptsResume = true,
    this.holdParts = false,
    this.holdFinishes = false,
    this.closesOnFinish = false,
  }) : capabilities = capabilities ?? defaultCapabilities;

  /// The part size of [defaultCapabilities]: 64 KiB.
  static const int defaultPartSize = 64 * 1024;

  /// Parts of [defaultPartSize], four of them in flight, resume without a
  /// window, references good for a day.
  static const UploadCapabilities defaultCapabilities = UploadCapabilities(
    partSize: _fakePartSize,
    bytesInFlight: 4 * defaultPartSize,
    resume: UploadResume.unlimited(),
    reuse: UploadReuse.lifetime(Duration(hours: 24)),
  );

  @override
  final String id;

  @override
  final UploadCapabilities capabilities;

  /// Whether a session opened with a token this fake issued continues.
  bool acceptsResume;

  /// Whether parts wait for [ack] or [reject].
  bool holdParts;

  /// Whether finishes wait for [answerFinish]. A finish not yet answered
  /// did not happen: the remote end still holds the upload open.
  bool holdFinishes;

  /// Whether an upload finished once refuses a second finish, with a
  /// refusal that does not pass, as a remote end that closes the upload
  /// when it completes; otherwise a second finish answers again.
  bool closesOnFinish;

  /// When the remote end forgets an upload, as each session opened from now
  /// on tells it ([UploadSession.resumeExpiresAt]); null to say nothing.
  /// The fake itself forgets nothing: the engine judges the expiry.
  DateTime? resumeExpiresAt;

  final List<FakeUploadOpen> _opens = [];
  final List<FakeUploadPart> _sent = [];
  final List<int> _acknowledged = [];
  final List<FakeUploadFinish> _finishes = [];
  final Set<String> _tokens = {};
  final Map<int, Queue<Exception>> _partFailures = {};
  final Queue<Exception> _openFailures = Queue();
  final Queue<Exception> _finishFailures = Queue();
  final List<(int, Completer<UploadPartAck>)> _held = [];
  final Queue<Completer<void>> _heldFinishes = Queue();
  final Set<String> _finished = {};
  int _bytesInFlight = 0;
  int _maxBytesInFlight = 0;

  /// Every open, oldest first.
  List<FakeUploadOpen> get opens => List.unmodifiable(_opens);

  /// Every part try, oldest first.
  List<FakeUploadPart> get sent => List.unmodifiable(_sent);

  /// The index of every acknowledged part, in the order acknowledged.
  List<int> get acknowledged => List.unmodifiable(_acknowledged);

  /// Every finish, oldest first.
  List<FakeUploadFinish> get finishes => List.unmodifiable(_finishes);

  /// The most bytes that were in flight at once.
  int get maxBytesInFlight => _maxBytesInFlight;

  /// The bytes in flight now.
  int get bytesInFlight => _bytesInFlight;

  /// The indexes of the held parts, oldest first, waiting for [ack] or
  /// [reject]; one index appears once per upload holding it.
  List<int> get held => [for (final (index, _) in _held) index];

  /// The next [times] tries of part [index] fail with [error] (by default
  /// a transient [UploadTransportException]).
  void failPart(int index, {int times = 1, Exception? error}) {
    final failures = _partFailures.putIfAbsent(index, Queue.new);
    for (var i = 0; i < times; i++) {
      failures.add(error ?? _transient);
    }
  }

  /// The next [times] opens fail with [error].
  void failOpen({int times = 1, Exception? error}) {
    for (var i = 0; i < times; i++) {
      _openFailures.add(error ?? _transient);
    }
  }

  /// The next [times] finishes fail with [error].
  void failFinish({int times = 1, Exception? error}) {
    for (var i = 0; i < times; i++) {
      _finishFailures.add(error ?? _transient);
    }
  }

  /// Acknowledges the oldest held part [index] with [receipt]
  /// (`receipt-<index>` by default).
  void ack(int index, {String? receipt}) => _takeHeld(
    index,
  ).complete(UploadPartAck(receipt: receipt ?? _receipt(index)));

  /// The finishes waiting for [answerFinish].
  int get heldFinishes => _heldFinishes.length;

  /// Lets the oldest held finish answer.
  void answerFinish() => _heldFinishes.removeFirst().complete();

  /// Fails the oldest held part [index]'s try with [error].
  void reject(int index, [Exception? error]) =>
      _takeHeld(index).completeError(error ?? _transient);

  @override
  Future<UploadSession> open(UploadInfo info, {String? resumeToken}) async {
    _opens.add(FakeUploadOpen(info, resumeToken));
    await null;
    if (_openFailures.isNotEmpty) throw _openFailures.removeFirst();
    final resumed =
        resumeToken != null && acceptsResume && _tokens.contains(resumeToken);
    final token = resumed ? resumeToken : 'fake-token-${_opens.length}';
    _tokens.add(token);
    return _FakeSession(
      this,
      token,
      resumed: resumed,
      resumeExpiresAt: resumeExpiresAt,
    );
  }

  static const _transient = UploadTransportException(
    'fake_failure',
    transient: true,
  );

  static String _receipt(int index) => 'receipt-$index';

  Completer<UploadPartAck> _takeHeld(int index) {
    for (final entry in _held) {
      if (entry.$1 != index) continue;
      _held.remove(entry);
      return entry.$2;
    }
    throw StateError('Part $index is not held.');
  }

  Future<UploadPartAck> _sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  }) async {
    _sent.add(
      FakeUploadPart(
        index: index,
        offset: offset,
        length: bytes.length,
        last: last,
      ),
    );
    _bytesInFlight += bytes.length;
    if (_bytesInFlight > _maxBytesInFlight) _maxBytesInFlight = _bytesInFlight;
    try {
      await null;
      final failures = _partFailures[index];
      if (failures != null && failures.isNotEmpty) throw failures.removeFirst();
      final UploadPartAck ack;
      if (holdParts) {
        final completer = Completer<UploadPartAck>();
        _held.add((index, completer));
        ack = await completer.future;
      } else {
        ack = UploadPartAck(receipt: _receipt(index));
      }
      _acknowledged.add(index);
      return ack;
    } finally {
      _bytesInFlight -= bytes.length;
    }
  }

  Future<RemoteRef> _finish(
    String token,
    int finalSize,
    List<UploadPartAck> parts,
  ) async {
    _finishes.add(FakeUploadFinish(finalSize, parts));
    // Numbered before the wait: finishes under way together get their own.
    final number = _finishes.length;
    await null;
    if (holdFinishes) {
      final held = Completer<void>();
      _heldFinishes.add(held);
      await held.future;
    }
    if (_finishFailures.isNotEmpty) throw _finishFailures.removeFirst();
    if (closesOnFinish && _finished.contains(token)) {
      throw const UploadTransportException('upload_closed', status: 404);
    }
    _finished.add(token);
    return RemoteRef('fake-$number');
  }
}

final class _FakeSession implements UploadSession {
  _FakeSession(
    this._transport,
    this.resumeToken, {
    required this.resumed,
    required this.resumeExpiresAt,
  });

  final FakeUploadTransport _transport;

  @override
  final String resumeToken;

  @override
  final bool resumed;

  @override
  final DateTime? resumeExpiresAt;

  @override
  Future<UploadPartAck> sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  }) => _transport._sendPart(index, offset, bytes, last: last);

  @override
  Future<RemoteRef> finish(int finalSize, List<UploadPartAck> parts) =>
      _transport._finish(resumeToken, finalSize, parts);
}

/// One [FakeUploadTransport.open]: what it was told.
@immutable
final class FakeUploadOpen {
  /// An open of [info] with [resumeToken].
  const FakeUploadOpen(this.info, this.resumeToken);

  /// The upload described.
  final UploadInfo info;

  /// The token it was opened with; null for a new upload.
  final String? resumeToken;

  @override
  String toString() => 'FakeUploadOpen($info, $resumeToken)';
}

/// One try of a part through a [FakeUploadTransport].
@immutable
final class FakeUploadPart {
  /// Part [index], [length] bytes from [offset].
  const FakeUploadPart({
    required this.index,
    required this.offset,
    required this.length,
    required this.last,
  });

  /// The part's index.
  final int index;

  /// Where it starts in the file.
  final int offset;

  /// Its size.
  final int length;

  /// Whether it is the final part.
  final bool last;

  @override
  bool operator ==(Object other) =>
      other is FakeUploadPart &&
      other.index == index &&
      other.offset == offset &&
      other.length == length &&
      other.last == last;

  @override
  int get hashCode => Object.hash(index, offset, length, last);

  @override
  String toString() =>
      'FakeUploadPart($index, $offset, $length${last ? ', last' : ''})';
}

/// One [UploadSession.finish] through a [FakeUploadTransport].
@immutable
final class FakeUploadFinish {
  /// A finish of [finalSize] bytes with [parts].
  FakeUploadFinish(this.finalSize, List<UploadPartAck> parts)
    : parts = List.unmodifiable(parts);

  /// The size finished.
  final int finalSize;

  /// The acknowledgements, in index order.
  final List<UploadPartAck> parts;
}
