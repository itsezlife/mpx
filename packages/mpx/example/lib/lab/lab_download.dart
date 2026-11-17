import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/lab/corpus.dart';

/// The throughput scenario: corpus entries downloaded whole through the
/// stack's bytes cache, timed per file.
///
/// Each file goes the way the fetcher fetches a missing part whole: the
/// stack's ranged resources, one ask to the end, through the stack's
/// client (its middlewares, slots and transfer worker). It runs one file
/// at a time, then all at once, each pass under keys of its own so both
/// start from nothing cached. A run starts cold on an empty home page
/// (`lab_open download`), so no tile competes for the link.
abstract final class LabDownload {
  /// Downloads [value] (`public`: every entry with an internet URL; else
  /// the entry of that file name) of [corpus] through [ranged], fetching
  /// each from [urlOf], and logs `dl` lines, ending with `dl done`.
  static Future<void> run({
    required RangedBytes ranged,
    required Corpus corpus,
    required String value,
    required Uri? Function(String file) urlOf,
    required void Function(String line) log,
  }) async {
    final entries = value == 'public'
        ? [
            for (final e in corpus.entries)
              if (e.url != null) e,
          ]
        : [?corpus.entryOf(value)];
    if (entries.isEmpty) {
      log('dl refused: no corpus entry for "$value"');
      return log('dl done');
    }
    log('dl start files=${entries.length}');

    final serial = Stopwatch()..start();
    final one = <_Download>[];
    for (final entry in entries) {
      one.add(await _download(ranged, entry, 'serial', urlOf, log));
    }
    _total('serial', one, serial.elapsed, log);

    final parallel = Stopwatch()..start();
    final all = await Future.wait([
      for (final entry in entries)
        _download(ranged, entry, 'parallel', urlOf, log),
    ]);
    _total('parallel', all, parallel.elapsed, log);
    log('dl done');
  }

  static Future<_Download> _download(
    RangedBytes ranged,
    CorpusEntry entry,
    String pass,
    Uri? Function(String file) urlOf,
    void Function(String line) log,
  ) async {
    final url = urlOf(entry.file);
    if (url == null) {
      log('dl ${entry.file} failed: no URL pass=$pass');
      return const _Download(0, Duration.zero);
    }
    final watch = Stopwatch()..start();
    final RangedResource resource;
    try {
      resource = await ranged.open(
        RangedRequest(
          url: url,
          // Keyed as the fetcher keys content, under a key per pass.
          cacheKey: BytesCacheFetcher.cacheKeyOf(
            MediaKey.remote('lab-dl-$pass-${entry.file}'),
            FetchPart.content,
          ),
          quota: BytesQuota.images,
        ),
      );
    } on Object catch (error) {
      log('dl ${entry.file} failed: $error pass=$pass');
      return const _Download(0, Duration.zero);
    }
    try {
      await resource.ensure(
        const ByteRange(0),
        priority: PriorityToken(RequestPriority.visible),
      );
    } on Object catch (error) {
      log('dl ${entry.file} failed: $error pass=$pass');
      return const _Download(0, Duration.zero);
    } finally {
      await resource.close();
    }
    final span = watch.elapsed;
    final bytes = resource.totalLength ?? resource.ranges.coveredBytes;
    log(
      'dl ${entry.file} bytes=$bytes span=${span.inMilliseconds}ms '
      'kbps=${_kbps(bytes, span)} pass=$pass',
    );
    return _Download(bytes, span);
  }

  static void _total(
    String pass,
    List<_Download> downloads,
    Duration span,
    void Function(String line) log,
  ) {
    final bytes = downloads.fold(0, (sum, d) => sum + d.bytes);
    log(
      'dl total pass=$pass files=${downloads.length} bytes=$bytes '
      'span=${span.inMilliseconds}ms kbps=${_kbps(bytes, span)}',
    );
  }

  /// Kilobits a second.
  static int _kbps(int bytes, Duration span) => span.inMicroseconds == 0
      ? 0
      : (bytes * 8 * 1000 / span.inMicroseconds).round();
}

final class _Download {
  const _Download(this.bytes, this.span);

  final int bytes;
  final Duration span;
}
