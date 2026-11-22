/// Prebuilt native libraries of the video decoder: which exist
/// (`native/prebuilts.json`), whether they fit these sources, and fetching
/// them verified into the hook's shared cache.
///
/// A target's prebuilt is several files: the wrapper (`libmpx_video`) and the
/// FFmpeg libraries it links, each bundled under the exact name its
/// dependents load it by (`name`). They are published as separate release
/// files (`file`), so the hook needs no archive reader.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One file of a target's prebuilt.
final class VideoPrebuiltFile {
  /// Creates the entry; use [VideoPrebuiltManifest.parse] for a validated
  /// one.
  const VideoPrebuiltFile({
    required this.name,
    required this.file,
    required this.sha256,
    required this.size,
  });

  /// The name the library is bundled and loaded under (`libavcodec.so`,
  /// `libavcodec.63.dylib`, `libmpx_video.dylib`).
  final String name;

  /// The release file under the manifest's `baseUrl`.
  final String file;

  /// The lower-case hex SHA-256 of the file.
  final String sha256;

  /// The file's length in bytes.
  final int size;
}

/// `native/prebuilts.json`, schema 1.
///
/// ```json
/// {
///   "schema": 1,
///   "sourceHash": "<videoSourceHash of the sources they were built from>",
///   "baseUrl": "https://github.com/<owner>/<repo>/releases/download/<tag>/",
///   "targets": {
///     "android-arm64": [
///       {"name": "libmpx_video.so", "file": "mpx_video-android-arm64-libmpx_video.so",
///        "sha256": "...", "size": 17280},
///       ...
///     ]
///   }
/// }
/// ```
///
/// Strict about what the hook acts on (names, hashes, sizes, the https
/// URL), lenient about unknown keys. An empty one (no `baseUrl`, no
/// targets) is valid: nothing is published.
final class VideoPrebuiltManifest {
  const VideoPrebuiltManifest._({
    required this.sourceHash,
    required this.baseUrl,
    required this.targets,
  });

  /// Parses [source]; throws a [FormatException] naming the offending field.
  factory VideoPrebuiltManifest.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('prebuilts.json is not JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('prebuilts.json must be a JSON object');
    }
    if (decoded['schema'] != 1) {
      throw FormatException(
        'prebuilts.json "schema" must be 1, found ${decoded['schema']}',
      );
    }
    final targets = decoded['targets'];
    if (targets is! Map<String, Object?>) {
      throw const FormatException('prebuilts.json "targets" must be an object');
    }
    return VideoPrebuiltManifest._(
      sourceHash: _hex(decoded['sourceHash'], 'sourceHash'),
      baseUrl: _baseUrl(decoded['baseUrl']),
      targets: {
        for (final MapEntry(:key, :value) in targets.entries)
          key: _files(key, value),
      },
    );
  }

  /// The [videoSourceHash] of the sources the files were built from: they
  /// apply only while it equals the hash of the sources in the package.
  final String sourceHash;

  /// Where the files are hosted (https, ending in `/`), or null.
  final Uri? baseUrl;

  /// The files of each target key.
  final Map<String, List<VideoPrebuiltFile>> targets;

  /// The files of the target [key], or null when none are published.
  List<VideoPrebuiltFile>? filesFor(String key) => targets[key];

  /// Where [file] is downloaded from: appended to the base path, never
  /// resolved against it, so a name cannot act as a relative reference.
  Uri? urlOf(VideoPrebuiltFile file) {
    final base = baseUrl;
    if (base == null) return null;
    return base.replace(path: '${base.path}${Uri.encodeComponent(file.file)}');
  }
}

final _hexDigest = RegExp(r'^[0-9a-f]{64}$');
final _fileName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

String _hex(Object? value, String field) {
  if (value is! String || !_hexDigest.hasMatch(value)) {
    throw FormatException(
      'prebuilts.json "$field" must be 64 lower-case hex digits',
    );
  }
  return value;
}

Uri? _baseUrl(Object? value) {
  if (value is! String) {
    throw const FormatException('prebuilts.json "baseUrl" must be a string');
  }
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      !uri.path.endsWith('/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException(
      'prebuilts.json "baseUrl" must be an https URL ending in "/": $value',
    );
  }
  return uri;
}

String _name(Object? value, String field) {
  if (value is! String || !_fileName.hasMatch(value) || value.contains('..')) {
    throw FormatException('prebuilts.json "$field" is not a plain file name');
  }
  return value;
}

List<VideoPrebuiltFile> _files(String key, Object? value) {
  if (value is! List<Object?> || value.isEmpty) {
    throw FormatException('prebuilts.json "targets.$key" must list files');
  }
  return [
    for (final entry in value)
      if (entry is Map<String, Object?>)
        VideoPrebuiltFile(
          name: _name(entry['name'], 'targets.$key[].name'),
          file: _name(entry['file'], 'targets.$key[].file'),
          sha256: _hex(entry['sha256'], 'targets.$key[].sha256'),
          size: switch (entry['size']) {
            final int size when size > 0 => size,
            _ => throw FormatException(
              'prebuilts.json "targets.$key[].size" must be positive',
            ),
          },
        )
      else
        throw FormatException(
          'prebuilts.json "targets.$key" holds a non-object',
        ),
  ];
}

// --- Source hash --------------------------------------------------------------

/// The files (under `native/`) the prebuilts are built from: the wrapper's
/// source and header, and the recipe with its pinned sources.
const videoSourceFiles = [
  'src/mpx_video.c',
  'include/mpx_video.h',
  'recipe/build.sh',
  'recipe/manifest.env',
];

/// The SHA-256 over [videoSourceFiles] under [native]: each path, then its
/// bytes with line endings made `\n`, so a Windows checkout hashes as the
/// one the prebuilts came from.
String videoSourceHash(Directory native) {
  final bytes = <int>[];
  for (final path in videoSourceFiles) {
    final text = File('${native.path}/$path').readAsStringSync();
    bytes
      ..addAll(utf8.encode(path))
      ..add(0)
      ..addAll(utf8.encode(text.replaceAll('\r\n', '\n')))
      ..add(0);
  }
  return sha256.convert(bytes).toString();
}

// --- Delivery order -----------------------------------------------------------

/// Where a target's libraries come from.
enum VideoDelivery {
  /// The FFmpeg build the app names (`hooks.user_defines`): a developer's
  /// own build, which wins so it can be tried.
  userPrefix,

  /// The published prebuilt, when it fits these sources and this target.
  prebuilt,

  /// A recipe build in the package itself, or `MPX_VIDEO_FFMPEG_DIR`.
  localPrefix,
}

/// The ways to try, in order: an app's own FFmpeg build first (a dev
/// override), then the prebuilt, then a local recipe build. Empty when
/// there is none: the build warns and bundles nothing.
List<VideoDelivery> planVideoDelivery({
  required bool userPrefix,
  required bool prebuilt,
  required bool localPrefix,
}) => [
  if (userPrefix) VideoDelivery.userPrefix,
  if (prebuilt) VideoDelivery.prebuilt,
  if (localPrefix) VideoDelivery.localPrefix,
];

// --- Fetch --------------------------------------------------------------------

/// The outcome of [fetchVideoPrebuilts].
sealed class VideoPrebuiltFetch {
  const VideoPrebuiltFetch();
}

/// Every file on disk, verified: by the name each is bundled under.
final class VideoPrebuiltsReady extends VideoPrebuiltFetch {
  /// Creates the result.
  const VideoPrebuiltsReady(this.files);

  /// The verified files, in the manifest's order.
  final Map<String, File> files;
}

/// No usable prebuilt; [reason] is a line for the build log.
final class VideoPrebuiltsUnavailable extends VideoPrebuiltFetch {
  /// Creates the result.
  const VideoPrebuiltsUnavailable(this.reason);

  /// Why.
  final String reason;
}

/// Resolves every one of [files] to a verified file under [cacheDir],
/// downloading from [urlOf] what is not there yet.
///
/// A file lives at `<cacheDir>/<sha256>/<name>`: keyed by its hash, so every
/// build of every app shares it and another build is another path, and kept
/// under the name the loader wants. A cached file is used only if its size
/// and hash still match. A download lands in a temporary file and is renamed
/// in only once verified, so a cut or wrong download leaves nothing behind.
/// Never throws: any failure is [VideoPrebuiltsUnavailable].
///
/// A file whose download fails is tried [attempts] times in all, [retryDelay]
/// apart: the hook's result is cached like any other, so a build that gave
/// up on one flaky answer would stay without its library until the next
/// `flutter clean`. [timeout] ends a download only when it stalls: no bytes
/// for that long.
Future<VideoPrebuiltFetch> fetchVideoPrebuilts({
  required List<VideoPrebuiltFile> files,
  required Uri? Function(VideoPrebuiltFile file) urlOf,
  required Directory cacheDir,
  Duration timeout = const Duration(minutes: 2),
  int attempts = 3,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final ready = <String, File>{};
  for (final entry in files) {
    final target = File('${cacheDir.path}/${entry.sha256}/${entry.name}');
    try {
      if (await _verified(target, entry)) {
        ready[entry.name] = target;
        continue;
      }
      final url = urlOf(entry);
      if (url == null) {
        return const VideoPrebuiltsUnavailable('no baseUrl in the manifest');
      }
      String? problem;
      for (var attempt = 1; attempt <= attempts; attempt++) {
        problem = await _download(url, target, entry, timeout);
        if (problem == null) break;
        if (attempt < attempts) await Future<void>.delayed(retryDelay);
      }
      if (problem != null) {
        return VideoPrebuiltsUnavailable('$problem ($attempts attempts)');
      }
      ready[entry.name] = target;
    } on Object catch (e) {
      return VideoPrebuiltsUnavailable('${entry.file}: $e');
    }
  }
  return VideoPrebuiltsReady(ready);
}

Future<bool> _verified(File file, VideoPrebuiltFile entry) async {
  if (!file.existsSync() || file.lengthSync() != entry.size) return false;
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == entry.sha256;
}

// The problem with the download, or null once [target] holds it, verified.
Future<String?> _download(
  Uri url,
  File target,
  VideoPrebuiltFile entry,
  Duration timeout,
) async {
  target.parent.createSync(recursive: true);
  final partial = File(
    '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return '${entry.file}: HTTP ${response.statusCode} from $url';
    }
    final sink = partial.openWrite();
    var received = 0;
    final hashSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(hashSink);
    try {
      await for (final chunk in response.timeout(timeout)) {
        received += chunk.length;
        if (received > entry.size) {
          return '${entry.file}: more than the manifest\'s ${entry.size} '
              'bytes';
        }
        sink.add(chunk);
        hasher.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    if (received != entry.size) {
      return '${entry.file}: $received bytes, the manifest says ${entry.size}';
    }
    final got = hashSink.value.toString();
    if (got != entry.sha256) {
      return '${entry.file}: SHA-256 $got, the manifest pins ${entry.sha256}';
    }
    partial.renameSync(target.path);
    return null;
  } on TimeoutException {
    return '${entry.file}: timed out after $timeout';
  } finally {
    client.close(force: true);
    if (partial.existsSync()) partial.deleteSync();
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
