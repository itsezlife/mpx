import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// How a corpus file plays.
enum CorpusKind {
  /// A video with sound: muted on the software decoder in a list, on the
  /// platform player with sound in the viewer.
  video(MediaKind.video, GalleryMediaKind.video),

  /// A silent loop (a GIF stand-in): the frame path everywhere.
  loop(MediaKind.video, GalleryMediaKind.animation),

  /// An animated image (WebP, GIF).
  animated(MediaKind.animatedImage, GalleryMediaKind.animation),

  /// A Lottie animation (JSON).
  lottie(MediaKind.vectorAnimation, GalleryMediaKind.animation),

  /// A still image.
  still(MediaKind.still, GalleryMediaKind.photo);

  const CorpusKind(this.media, this.gallery);

  final MediaKind media;
  final GalleryMediaKind gallery;
}

/// One file of the corpus, as its manifest describes it.
final class CorpusEntry {
  const CorpusEntry({
    required this.file,
    required this.kind,
    this.url,
    this.codec,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
    this.duration,
    this.size,
  });

  factory CorpusEntry.fromJson(Map<String, Object?> json) => CorpusEntry(
    file: json['file']! as String,
    kind: CorpusKind.values.byName(json['kind']! as String),
    url: switch (json['url']) {
      final String url => Uri.parse(url),
      _ => null,
    },
    codec: json['codec'] as String?,
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    fps: (json['fps'] as num?)?.toDouble(),
    bitrate: (json['bitrate'] as num?)?.toInt(),
    duration: (json['duration'] as num?)?.toDouble(),
    size: (json['size'] as num?)?.toInt(),
  );

  /// The file's name: in the corpus folder for a local entry, the name
  /// the run reports for a remote one.
  final String file;
  final CorpusKind kind;

  /// Where a public entry lives on the internet; null for a file of the
  /// corpus folder only.
  final Uri? url;
  final String? codec;
  final int? width;
  final int? height;
  final double? fps;

  /// Bits per second.
  final int? bitrate;

  /// Seconds.
  final double? duration;

  /// Bytes.
  final int? size;

  /// One line for the run's log: name, kind, codec, resolution, fps,
  /// bitrate, duration, size.
  String describe() =>
      '$file ${kind.name} ${codec ?? '?'} '
      '${width ?? '?'}x${height ?? '?'} '
      '${fps?.toStringAsFixed(2) ?? '?'}fps '
      '${bitrate == null ? '?' : '${(bitrate! / 1000).round()}kbps'} '
      '${duration?.toStringAsFixed(1) ?? '?'}s '
      '${size ?? '?'}B ${url?.host ?? 'local'}';
}

/// The media a lab run plays: the files of `<files dir>/corpus/` that its
/// `manifest.json` lists (`{"entries": [{"file", "kind", ...}]}`).
final class Corpus {
  const Corpus(this.directory, this.entries);

  /// The corpus under [directory], or null without a manifest or entries.
  /// A local entry (no `url`) whose file is missing is left out.
  static Future<Corpus?> load(String directory) async {
    final manifest = File('$directory/manifest.json');
    if (!manifest.existsSync()) return null;
    final json =
        jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
    final entries = [
      for (final e in json['entries']! as List<Object?>)
        CorpusEntry.fromJson(e! as Map<String, Object?>),
    ].where((e) => e.url != null || hasFile(directory, e)).toList();
    return entries.isEmpty ? null : Corpus(directory, entries);
  }

  final String directory;
  final List<CorpusEntry> entries;

  /// Whether [entry]'s file is in [directory].
  static bool hasFile(String directory, CorpusEntry entry) =>
      File('$directory/${entry.file}').existsSync();

  /// The entry named [file], or null.
  CorpusEntry? entryOf(String file) =>
      entries.where((e) => e.file == file).firstOrNull;

  /// A short hash of the files and their sizes: two runs on one corpus
  /// share it.
  String get fingerprint {
    var hash = 0x811c9dc5;
    for (final e in entries) {
      for (final unit in '${e.file}:${e.size}:${e.kind.name};'.codeUnits) {
        hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
      }
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// A loopback HTTP origin over a folder: answers `GET /<file>` with the
/// file's bytes, a single-range request with its range, as a CDN would,
/// at an optional bandwidth and first-byte latency, so the bytes cache and
/// the ranged reads run as against a network.
final class LoopbackOrigin {
  LoopbackOrigin._(this._server, this.directory);

  /// Serves [directory] on a free loopback port.
  static Future<LoopbackOrigin> serve(String directory) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = LoopbackOrigin._(server, directory);
    server.listen(origin._handle);
    return origin;
  }

  final HttpServer _server;
  final String directory;

  /// Bytes per second each response is held to; null for no limit.
  int? bytesPerSecond;

  /// Delay before each response's first byte.
  Duration latency = Duration.zero;

  /// Requests answered and bytes sent so far.
  int requests = 0;
  int bytesSent = 0;

  Uri urlOf(String file) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: '/$file',
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    requests++;
    final name = request.uri.pathSegments.lastOrNull;
    final file = File('$directory/$name');
    if (name == null || name.contains('..') || !file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final length = file.lengthSync();
    var start = 0;
    var last = length - 1;
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null && int.parse(range.group(1)!) < length) {
      start = int.parse(range.group(1)!);
      last = math.min(int.tryParse(range.group(2)!) ?? last, length - 1);
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$last/$length',
        );
    }
    response.contentLength = last - start + 1;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final clock = Stopwatch()..start();
    var sent = 0;
    try {
      await for (final chunk in file.openRead(start, last + 1)) {
        response.add(chunk);
        sent += chunk.length;
        bytesSent += chunk.length;
        final rate = bytesPerSecond;
        if (rate != null && rate > 0) {
          final due = Duration(microseconds: sent * 1000000 ~/ rate);
          final ahead = due - clock.elapsed;
          if (ahead > Duration.zero) await Future<void>.delayed(ahead);
        }
      }
      await response.close();
    } on Object {
      // The client went away (a cancelled read); nothing to answer.
    }
  }
}
