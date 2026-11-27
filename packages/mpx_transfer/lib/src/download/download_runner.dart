import 'dart:async';

import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/download/downloaded_content.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/engine/transfer_runner.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';

/// Moves tracked downloads' bytes: each run fetches the whole content
/// through the host's fetcher, which lands it in the bytes cache.
///
/// The job holds state only. A stopped run cancels its fetch; the bytes the
/// cache kept are where the next run goes on from, which is the fetcher's
/// ranged resume. A priority change before the first byte moves the request
/// in the cache's queue by asking again at the new priority; once bytes
/// move, the request holds its slot and the change applies to the next run.
///
/// Internal to the package.
final class DownloadRunner implements TransferRunner {
  /// A runner over [downloads].
  DownloadRunner(this.downloads);

  /// The fetcher, resolver and store the runs use.
  final TransferDownloads downloads;

  final Map<TransferId, _DownloadRun> _runs = {};

  @override
  void start(TransferJob job, TransferRunSink sink) {
    final key = job.key;
    if (key == null) {
      sink.fail(TransferFailureKind.local, retryable: false);
      return;
    }
    stop(job.id);
    final run = _runs[job.id] = _DownloadRun(this, job.id, key, sink)
      ..priority = job.priority;
    unawaited(run.go());
  }

  @override
  void stop(TransferId id) => _runs.remove(id)?.stop();

  @override
  void reprioritize(TransferId id, RequestPriority priority) =>
      _runs[id]?.reprioritize(priority);

  void _ended(_DownloadRun run) {
    if (identical(_runs[run.id], run)) _runs.remove(run.id);
  }
}

final class _DownloadRun {
  _DownloadRun(this._runner, this.id, this.key, this._sink);

  final DownloadRunner _runner;
  final TransferId id;
  final MediaKey key;
  final TransferRunSink _sink;

  RequestPriority priority = RequestPriority.visible;
  MediaDescriptor? _descriptor;
  CancellationToken? _fetch;
  bool _stopped = false;
  bool _received = false;
  int _done = 0;
  int? _total;

  TransferDownloads get _downloads => _runner.downloads;

  Future<void> go() async {
    final MediaDescriptor? descriptor;
    try {
      descriptor = (await _downloads.resolver.resolve([key]))[key];
    } on Object {
      _fail(AssetFailureKind.transient);
      return;
    }
    if (_stopped) return;
    if (descriptor == null) {
      // A key the host cannot describe has no content to fetch.
      _fail(AssetFailureKind.permanent);
      return;
    }
    _descriptor = descriptor;
    _fetchContent();
  }

  void _fetchContent() {
    final descriptor = _descriptor!;
    final token = _fetch = CancellationToken();
    unawaited(
      _downloads.fetcher
          .fetch(
            FetchRequest(
              descriptor: descriptor,
              part: FetchPart.content,
              priority: _assetPriority(priority),
              cancellation: token,
              whole: true,
              onProgress: (received, total) {
                if (_stopped || !identical(_fetch, token)) return;
                _received = true;
                _done = received;
                _total = total ?? descriptor.byteSize;
                _sink.progress(received, total: _total);
              },
            ),
          )
          .then(
            (content) => _landed(token, content),
            onError: (Object error) {
              if (_stopped || !identical(_fetch, token)) return;
              _fail(switch (error) {
                FetchFailure(:final kind) => kind,
                _ => AssetFailureKind.transient,
              });
            },
          ),
    );
  }

  Future<void> _landed(CancellationToken token, FetchedContent content) async {
    // A ranged resource handed out while it still arrives is whole once its
    // rest is; until then the run goes on reporting what lands.
    if (content case FetchedRanged(:final rest?)) {
      try {
        await rest;
      } on Object catch (error) {
        content.release();
        if (_stopped || !identical(_fetch, token)) return;
        _fail(switch (error) {
          FetchFailure(:final kind) => kind,
          _ => AssetFailureKind.transient,
        });
        return;
      }
    }
    content.release();
    if (_stopped || !identical(_fetch, token)) return;
    _runner._ended(this);
    _sink.complete(
      DownloadedContent(bytes: _total ?? (_received ? _done : null)),
    );
  }

  void reprioritize(RequestPriority next) {
    if (next == priority) return;
    priority = next;
    if (_received || _descriptor == null || _stopped) return;
    // Still queued in the cache: ask again at the new priority. Nothing has
    // landed, so nothing is lost.
    final previous = _fetch;
    _fetch = null;
    previous?.cancel();
    _fetchContent();
  }

  void stop() {
    _stopped = true;
    _fetch?.cancel();
  }

  void _fail(AssetFailureKind kind) {
    _runner._ended(this);
    switch (kind) {
      case AssetFailureKind.transient:
        _sink.fail(TransferFailureKind.network, retryable: true);
      case AssetFailureKind.permanent:
        _sink.fail(TransferFailureKind.server, retryable: false);
    }
  }

  // The fetch seam's urgencies have no background below preload: background
  // downloads are asked at preload.
  static AssetPriority _assetPriority(RequestPriority priority) =>
      switch (priority) {
        RequestPriority.visible => AssetPriority.visible,
        RequestPriority.preload ||
        RequestPriority.background => AssetPriority.preload,
      };
}
