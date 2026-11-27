import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/diagnostics/transport_op.dart';
import 'package:mpx_transfer/src/engine/connection_slots.dart';
import 'package:mpx_transfer/src/engine/transfer_runner.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_part_source.dart';
import 'package:mpx_transfer/src/upload/upload_source.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// The runner of upload jobs: it splits each job's file into the parts its
/// transport declares, keeps the transport's bytes in flight, retries a
/// failed part, journals every acknowledged part and runs the jobs in two
/// lanes under the shared connection cap.
///
/// - **Lanes.** A job waits in its lane ([UploadLane]), which runs one job
///   at a time; the small and the big lane run beside each other. A job
///   stays queued while it waits, so its `jobStarted` carries the wait.
/// - **Parts.** Every part but the last is [UploadCapabilities.partSize]
///   long. Parts go out in index order while the bytes outstanding stay
///   within [UploadCapabilities.bytesInFlight] (one part always may), and
///   are acknowledged in any order.
/// - **Retry.** Each try of a part, of opening and of finishing holds one
///   connection of [slots] and none while it waits; a failure that may pass
///   is tried again after [retry]'s backoff, five tries in all with the
///   default preset, then the upload fails.
/// - **Journal.** An acknowledged part is kept with the job's next progress
///   write, so a kill loses at most one progress window of them; a restart
///   reopens with the journaled resume token and sends only the parts not
///   kept. A transport that cannot reopen, or a session that does not
///   continue, starts the upload from zero.
///
/// Part bodies go out through [client]: on the VM on the bytes cache's
/// transfer worker, streamed from the file at the source's path; on the web
/// through `fetch` with a slice of the page's source ([keepPageSource]) or,
/// after a reload, of its copy in OPFS (`sourceCopies`).
///
/// Internal to the package: hosts reach uploads through the facade.
final class UploadEngine implements TransferRunner {
  /// An engine over [journal] that sends through [transports].
  UploadEngine({
    required TransferJournal journal,
    required Iterable<UploadTransport> transports,
    ConnectionSlots? slots,
    HttpBytesClient? client,
    UploadSourceCopies? sourceCopies,
    this.retry = HttpBytesRetryBackoff.uploadPart,
    this.laneSplit = UploadLane.defaultSplit,
    math.Random? random,
    Future<void> Function(Duration delay)? wait,
    DateTime Function() now = DateTime.now,
  }) : _journal = journal,
       _transports = {
         for (final transport in transports) transport.id: transport,
       },
       slots = slots ?? ConnectionSlots(),
       _client = client,
       _sourceCopies = sourceCopies,
       _random = random ?? math.Random(),
       _wait = wait ?? Future<void>.delayed,
       _now = now;

  /// The backoff between two tries of a part: by default the bytes cache's
  /// preset for upload parts, five tries in all, waits from 1 s to 30 s.
  final HttpBytesRetryBackoff retry;

  /// The largest file the small lane takes when the caller names no lane:
  /// [UploadLane.defaultSplit] by default.
  final int laneSplit;

  /// The connections every request of the engine shares.
  final ConnectionSlots slots;

  final TransferJournal _journal;
  final Map<String, UploadTransport> _transports;
  final HttpBytesClient? _client;
  final UploadSourceCopies? _sourceCopies;
  final Map<TransferId, SourceBytes> _pageSources = {};
  final math.Random _random;
  final Future<void> Function(Duration delay) _wait;
  final DateTime Function() _now;

  final Map<UploadLane, _Lane> _lanes = {
    for (final lane in UploadLane.values) lane: _Lane(),
  };
  int _partRetries = 0;
  int _restartsFromZero = 0;

  /// The journal's facts for an upload of [source] through transport
  /// [transport]: what a new upload job is made with.
  ///
  /// [lane] defaults by the file's size against [laneSplit]; the caller
  /// names [UploadLane.big] for a video. [fingerprint] is the host's value
  /// for the file's content, else its size.
  ///
  /// Throws an [UnsupportedError] for a growing source, which this engine
  /// does not upload yet, and an [ArgumentError] for a transport it was
  /// not given.
  JournalUpload describe(
    UploadSource source, {
    required String transport,
    UploadLane? lane,
    String? fileName,
    String? contentType,
    String? fingerprint,
  }) {
    final finished = switch (source) {
      final UploadSource$Finished finished => finished,
      UploadSource$Growing() => throw UnsupportedError(
        'A growing upload source is not supported yet.',
      ),
    };
    final carrier =
        _transports[transport] ??
        (throw ArgumentError.value(
          transport,
          'transport',
          'is not one of the engine transports',
        ));
    return JournalUpload(
      source: JournalSource(
        path: finished.path,
        size: finished.size,
        fingerprint: fingerprint ?? '${finished.size}',
      ),
      transportId: carrier.id,
      lane: lane ?? UploadLane.forSize(finished.size, split: laneSplit),
      partSize: _partSizeOf(carrier, finished.size),
      fileName: fileName,
      contentType: contentType,
    );
  }

  /// Job [id] reads [bytes], the page's own source, on the web: a file the
  /// user picked or bytes in memory, kept until the job completes. After a
  /// reload the job reads its copy in OPFS instead.
  void keepPageSource(TransferId id, SourceBytes bytes) =>
      _pageSources[id] = bytes;

  /// The uploads section of a debug snapshot.
  UploadsDebugSnapshot debugSnapshot() => UploadsDebugSnapshot(
    lanes: {
      for (final MapEntry(key: lane, value: queue) in _lanes.entries)
        lane: UploadLaneDebugSnapshot(
          running: queue.running?.id,
          queued: queue.waiting.length,
        ),
    },
    partsInFlight: _lanes.values.fold(
      0,
      (sum, lane) => sum + (lane.running?._inFlight.length ?? 0),
    ),
    partRetries: _partRetries,
    restartsFromZero: _restartsFromZero,
  );

  // --- TransferRunner --------------------------------------------------------

  @override
  void start(TransferJob job, TransferRunSink sink) {
    final lane =
        _lanes[_journal.record(job.id)?.upload?.lane] ??
        _lanes[UploadLane.small]!;
    final run = _UploadRun(this, job.id, sink, lane);
    if (lane.running == null) {
      lane.running = run;
      unawaited(run.begin());
    } else {
      lane.waiting.add(run);
    }
  }

  @override
  void stop(TransferId id) {
    for (final lane in _lanes.values) {
      lane.waiting.removeWhere((run) => run.id == id);
      final running = lane.running;
      if (running?.id == id) running!.stop();
    }
  }

  /// Lanes run in arrival order: a priority change moves nothing.
  @override
  void reprioritize(TransferId id, RequestPriority priority) {}

  // --- Internals -------------------------------------------------------------

  static int _partSizeOf(UploadTransport transport, int size) {
    final partSize = transport.capabilities.partSize(size);
    if (partSize <= 0) {
      throw StateError(
        'Transport ${transport.id} declared a part size of $partSize.',
      );
    }
    return partSize;
  }

  /// [run] ended: its lane takes the next job.
  void _ended(_UploadRun run) {
    final lane = run.lane;
    if (!identical(lane.running, run)) return;
    lane.running = null;
    if (lane.waiting.isEmpty) return;
    final next = lane.running = lane.waiting.removeFirst();
    unawaited(next.begin());
  }

  Future<HttpBytesResponse> _send(
    TransferId id,
    JournalSource source,
    Uri url, {
    required int offset,
    required int length,
    required List<int> prefix,
    required List<int> suffix,
    required String method,
    required CancelToken cancelToken,
    required BytesProgressCallback onBytesSent,
    Map<String, String>? headers,
    Map<String, Object?>? context,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('No HTTP client is wired for upload parts.');
    }
    final bytes = _pageSources[id] ?? await _sourceCopies?.read(id, 0);
    // No retry here: the engine retries the part, so its tries are counted
    // and reported once.
    return client.upload(
      url,
      body: uploadPartBody(
        source,
        bytes,
        offset: offset,
        length: length,
        prefix: prefix,
        suffix: suffix,
      ),
      method: method,
      headers: headers,
      cancelToken: cancelToken,
      onBytesSent: onBytesSent,
      context: context,
    );
  }
}

/// One lane: the job it runs and the jobs waiting, in arrival order.
final class _Lane {
  _UploadRun? running;
  final Queue<_UploadRun> waiting = Queue();
}

/// The steps of a session whose tries are retried.
enum _Step { open, part, finish }

/// One run of one upload job, from opening its session to finishing it.
final class _UploadRun {
  _UploadRun(this._engine, this.id, this._sink, this.lane);

  final UploadEngine _engine;
  final TransferId id;
  final TransferRunSink _sink;
  final _Lane lane;

  final CancelToken _cancel = CancelToken();
  bool _ended = false;
  bool _finishing = false;

  late final JournalSource _source;
  late final int _partSize;
  late final int _budget;
  late final int _partCount;
  late final UploadSession _session;
  late final DateTime _began;

  final Map<int, UploadPartAck> _acks = {};
  final Queue<int> _pending = Queue();

  /// The parts on the wire: index to the bytes its try has sent so far.
  final Map<int, int> _inFlight = {};

  TransferJournal get _journal => _engine._journal;

  int get _size => _source.size;

  // --- Steps -----------------------------------------------------------------

  Future<void> begin() async {
    _began = _engine._now();
    final upload = _journal.record(id)?.upload;
    final transport = _engine._transports[upload?.transportId];
    if (upload == null || transport == null) {
      _gaveUpOpening(upload == null ? 'no_upload' : 'unknown_transport');
      return _fail(TransferFailureKind.local, retryable: false);
    }
    _source = upload.source;
    // A transport is asked again at each run: its declaration may have
    // changed since the job was made.
    final partSize = transport.capabilities.partSize(_size);
    if (partSize <= 0) {
      _gaveUpOpening('bad_part_size');
      return _fail(TransferFailureKind.local, retryable: false);
    }
    _partSize = partSize;
    _budget = transport.capabilities.bytesInFlight;
    _partCount = _size == 0 ? 1 : (_size + partSize - 1) ~/ partSize;

    // Parts acknowledged under another split name other bytes, so only an
    // upload split the same way may continue.
    final token =
        transport.capabilities.resume is UploadResume$None ||
            upload.partSize != partSize
        ? null
        : upload.resumeToken;
    final info = UploadInfo(
      size: _size,
      partSize: partSize,
      partCount: _partCount,
      fileName: upload.fileName,
      contentType: upload.contentType,
    );
    final UploadSession session;
    try {
      session = await _attempt(
        _Step.open,
        () => transport.open(info, resumeToken: token),
      );
    } on _RunEnded {
      return;
    } on _GaveUp catch (gaveUp) {
      return _fail(gaveUp.kind, retryable: gaveUp.retryable);
    }
    _session = session;

    final resumed = token != null && session.resumed;
    if (resumed) {
      for (final MapEntry(key: index, value: receipt) in upload.parts.entries) {
        if (index < _partCount) _acks[index] = UploadPartAck(receipt: receipt);
      }
    } else if (upload.parts.isNotEmpty) {
      _engine._restartsFromZero++;
    }
    for (var index = 0; index < _partCount; index++) {
      if (!_acks.containsKey(index)) _pending.add(index);
    }
    final highWaterMark = _highWaterMark();
    _journal.amendUpload(
      id,
      (upload) => JournalUpload(
        source: upload.source,
        transportId: upload.transportId,
        lane: upload.lane,
        partSize: partSize,
        fileName: upload.fileName,
        contentType: upload.contentType,
        resumeToken: session.resumeToken,
        parts: _receipts(),
        highWaterMark: highWaterMark,
      ),
    );
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      TransportOp.sessionOpened,
      jobId: id,
      fields: () => {
        'transport': transport.id,
        'resumed': resumed,
        'offset': highWaterMark,
        'size': _size,
      },
    );
    // The first report moves the job to running, a state write that takes
    // the session's token with it.
    _reportProgress();
    _pump();
  }

  /// Starts the next parts while the bytes outstanding stay within the
  /// budget; finishes once every part is acknowledged.
  void _pump() {
    if (_ended || _finishing) return;
    final budget = _budget;
    while (_pending.isNotEmpty) {
      final index = _pending.first;
      final length = _lengthOf(index);
      if (_inFlight.isNotEmpty && _outstanding + length > budget) break;
      _pending.removeFirst();
      _inFlight[index] = 0;
      unawaited(_sendPart(index, length));
    }
    if (_pending.isEmpty && _inFlight.isEmpty) unawaited(_finish());
  }

  Future<void> _sendPart(int index, int length) async {
    final offset = index * _partSize;
    var sentAt = _engine._now();
    final UploadPartAck ack;
    try {
      ack = await _attempt(_Step.part, index: index, () {
        // A try again starts the part's bytes from zero.
        _inFlight[index] = 0;
        sentAt = _engine._now();
        MpxDiagnostics.current.emit(
          MpxEventLevel.trace,
          TransportOp.partSent,
          jobId: id,
          fields: () => {
            'index': index,
            'offset': offset,
            'bytes': length,
            'inFlight': _outstanding,
          },
        );
        return _session.sendPart(
          index,
          offset,
          _body(index, offset, length),
          last: index == _partCount - 1,
        );
      });
    } on _RunEnded {
      return;
    } on _GaveUp catch (gaveUp) {
      return _fail(gaveUp.kind, retryable: gaveUp.retryable);
    }
    if (_ended) return;
    _inFlight.remove(index);
    _acks[index] = ack;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      TransportOp.partAcked,
      jobId: id,
      fields: () => {
        'index': index,
        'ms': _engine._now().difference(sentAt).inMilliseconds,
      },
    );
    final parts = _receipts();
    final highWaterMark = _highWaterMark();
    _journal.amendUpload(
      id,
      (upload) => upload.copyWith(parts: parts, highWaterMark: highWaterMark),
    );
    // The progress write carries the part to storage.
    _reportProgress();
    _pump();
  }

  Future<void> _finish() async {
    _finishing = true;
    final parts = [for (var i = 0; i < _partCount; i++) _acks[i]!];
    final RemoteRef ref;
    try {
      ref = await _attempt(_Step.finish, () => _session.finish(_size, parts));
    } on _RunEnded {
      return;
    } on _GaveUp catch (gaveUp) {
      return _fail(gaveUp.kind, retryable: gaveUp.retryable);
    }
    if (_ended) return;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      TransportOp.finished,
      jobId: id,
      fields: () => {
        'finalSize': _size,
        'parts': _partCount,
        'ms': _engine._now().difference(_began).inMilliseconds,
      },
    );
    // A completed upload needs neither its parts nor its token again; the
    // completion's state write keeps the record small.
    _journal.amendUpload(
      id,
      (upload) => upload.copyWith(parts: const {}, clearResumeToken: true),
    );
    _end();
    _engine._pageSources.remove(id);
    _sink.complete(ref);
  }

  void stop() {
    if (_ended) return;
    _end();
  }

  void _fail(TransferFailureKind kind, {required bool retryable}) {
    if (_ended) return;
    _end();
    _sink.fail(kind, retryable: retryable);
  }

  void _end() {
    _ended = true;
    _inFlight.clear();
    _cancel.cancel();
    _engine._ended(this);
  }

  // --- Tries -----------------------------------------------------------------

  /// Runs [send] until a try succeeds, holding a connection for each try
  /// and none while it waits for the next.
  ///
  /// Throws [_RunEnded] once the run ended, and [_GaveUp] when a try failed
  /// and no try follows: the failure cannot pass, or the backoff's tries or
  /// budget ran out.
  Future<T> _attempt<T>(
    _Step step,
    Future<T> Function() send, {
    int? index,
  }) async {
    var slept = Duration.zero;
    final retry = _engine.retry;
    for (var attempt = 0; ; attempt++) {
      final slot = await _engine.slots.acquire(TransferDirection.upload, id);
      if (_ended) {
        slot.release();
        throw const _RunEnded();
      }
      late final Object error;
      late final StackTrace stackTrace;
      try {
        return await send();
      } on Object catch (e, s) {
        error = e;
        stackTrace = s;
      } finally {
        slot.release();
      }
      if (_ended) throw const _RunEnded();
      final failure = _Failure.of(error);
      final delay = failure.transient && attempt < retry.maxRetries
          ? retry.backoff(attempt, _engine._random)
          : null;
      if (delay == null || !retry.withinBudget(slept, delay)) {
        MpxDiagnostics.current.emit(
          MpxEventLevel.error,
          TransportOp.partGaveUp,
          jobId: id,
          fields: () => {
            'step': step.name,
            'index': ?index,
            'attempts': attempt + 1,
            ...failure.fields,
          },
          stackTrace: stackTrace,
        );
        // Tries that ran out on a failure that may pass leave the job
        // worth a retry; a refusal does not.
        throw _GaveUp(failure.kind, retryable: failure.transient);
      }
      _engine._partRetries++;
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        TransportOp.partRetry,
        jobId: id,
        fields: () => {
          'step': step.name,
          'index': ?index,
          'attempt': attempt + 1,
          'delayMs': delay.inMilliseconds,
          ...failure.fields,
        },
      );
      await _engine._wait(delay);
      slept += delay;
      if (_ended) throw const _RunEnded();
    }
  }

  void _gaveUpOpening(String code) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    TransportOp.partGaveUp,
    jobId: id,
    fields: () => {'step': _Step.open.name, 'attempts': 0, 'code': code},
  );

  // --- Parts -----------------------------------------------------------------

  UploadPartBody _body(int index, int offset, int length) => UploadPartBody(
    length,
    (
      url, {
      required method,
      required prefix,
      required suffix,
      headers,
      context,
    }) => _engine._send(
      id,
      _source,
      url,
      offset: offset,
      length: length,
      prefix: prefix,
      suffix: suffix,
      method: method,
      headers: headers,
      context: context,
      cancelToken: _cancel,
      onBytesSent: (sent, _) {
        if (_ended || !_inFlight.containsKey(index)) return;
        // The transport's framing is not the file's bytes.
        _inFlight[index] = (sent - prefix.length).clamp(0, length);
        _reportProgress();
      },
    ),
  );

  int _lengthOf(int index) =>
      index == _partCount - 1 ? _size - index * _partSize : _partSize;

  /// The bytes of the parts on the wire, each counted whole.
  int get _outstanding =>
      _inFlight.keys.fold(0, (sum, index) => sum + _lengthOf(index));

  /// Every part before it is acknowledged.
  int _highWaterMark() {
    var index = 0;
    while (_acks.containsKey(index)) {
      index++;
    }
    return math.min(index * _partSize, _size);
  }

  Map<int, String?> _receipts() => {
    for (final MapEntry(key: index, value: ack) in _acks.entries)
      index: ack.receipt,
  };

  void _reportProgress() {
    if (_ended) return;
    var done = 0;
    for (final index in _acks.keys) {
      done += _lengthOf(index);
    }
    for (final sent in _inFlight.values) {
      done += sent;
    }
    _sink.progress(done, total: _size);
  }
}

/// What a failed try was, as the engine judges whether to try again.
final class _Failure {
  const _Failure(
    this.kind, {
    required this.transient,
    required this.code,
    this.status,
  });

  /// Reads [error]: a transport's own exception says what it is; the bytes
  /// cache's is judged as the bytes cache judges an upload's try.
  factory _Failure.of(Object error) => switch (error) {
    UploadTransportException(
      :final kind,
      :final transient,
      :final code,
      :final status,
    ) =>
      _Failure(kind, transient: transient, code: code, status: status),
    HttpBytesException$Network(:final code) ||
    HttpBytesException$Timeout(:final code) ||
    HttpBytesException$Cancelled(
      :final code,
    ) => _Failure(TransferFailureKind.network, transient: true, code: code),
    HttpBytesException(:final code, :final statusCode) => _Failure(
      TransferFailureKind.server,
      transient: HttpBytesRetryMiddleware.defaultRetryEvaluator(error, 0),
      code: code,
      status: statusCode,
    ),
    _ => const _Failure(
      TransferFailureKind.local,
      transient: false,
      code: 'unexpected',
    ),
  };

  final TransferFailureKind kind;
  final bool transient;
  final String code;
  final int? status;

  /// The status when the failure was an answer, else the code.
  Map<String, Object> get fields => switch (status) {
    final status? when status > 0 => {'status': status},
    _ => {'code': MpxEvent.clip(code)},
  };
}

/// The run ended while a try or a wait was under way.
final class _RunEnded implements Exception {
  const _RunEnded();
}

/// A step's tries ran out; the upload fails with [kind].
final class _GaveUp implements Exception {
  const _GaveUp(this.kind, {required this.retryable});

  final TransferFailureKind kind;
  final bool retryable;
}
