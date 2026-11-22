/// Turns the recipe builds under `native/.build/` into release files and the
/// manifest that names them. From the package root:
///
/// ```sh
/// dart native/tool/build_prebuilts.dart <out dir> --base-url <https url ending />
/// ```
///
/// For every recipe target that has a build here, the wrapper is compiled
/// exactly as the build hook compiles it, and the wrapper and the FFmpeg
/// libraries are copied to `<out>/mpx_video-<key>-<name>` (`name` being what
/// the loader asks for). Beside them: `ffmpeg-configure-<key>.txt` (the
/// configure line, part of the LGPL disclosure) and `prebuilts.json`, the
/// manifest for these sources, to copy into `native/`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';

import '../../hook/src/android_ndk.dart';
import '../../hook/src/ffmpeg_prefix.dart';
import '../../hook/src/video_prebuilts.dart';
import '../../hook/src/video_target.dart';
import '../../hook/src/wrapper_compile.dart';

// The floors the prebuilts serve: the recipe's Android API and Flutter's iOS
// minimum, so one build fits every app.
const _androidApi = 24;
const _iosVersion = 13;

// Every target the recipe builds, with what the wrapper compile needs.
const _targets = <(String, OS, Architecture, IOSSdk?)>[
  ('macos-arm64', OS.macOS, Architecture.arm64, null),
  ('macos-x64', OS.macOS, Architecture.x64, null),
  ('ios-arm64', OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS),
  ('ios-sim-arm64', OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator),
  ('android-arm64', OS.android, Architecture.arm64, null),
  ('android-arm', OS.android, Architecture.arm, null),
  ('android-x64', OS.android, Architecture.x64, null),
];

Future<void> main(List<String> args) async {
  final baseAt = args.indexOf('--base-url');
  if (args.isEmpty || baseAt < 0 || baseAt + 1 >= args.length) {
    stderr.writeln(
      'usage: dart native/tool/build_prebuilts.dart <out dir> '
      '--base-url <https url ending />',
    );
    exitCode = 64;
    return;
  }
  final out = Directory(args.first)..createSync(recursive: true);
  final baseUrl = args[baseAt + 1];
  final native = File.fromUri(Platform.script).parent.parent;
  final work = Directory('${native.path}/.build/prebuilt-wrappers')
    ..createSync(recursive: true);

  final targets = <String, List<Map<String, Object>>>{};
  var failed = false;
  for (final (recipe, os, arch, sdk) in _targets) {
    final prefix = Directory('${native.path}/.build/$recipe/prefix');
    if (!Directory('${prefix.path}/lib').existsSync()) {
      stdout.writeln('$recipe: no recipe build here, skipped');
      continue;
    }
    final key = manifestKeyOf(recipe);
    try {
      final libraries = bundledLibraries(prefix, os: os);
      final wrapperName = os == OS.android
          ? 'libmpx_video.so'
          : 'libmpx_video.dylib';
      final wrapperOut = File('${work.path}/$recipe/$wrapperName')
        ..parent.createSync(recursive: true);
      final wrapper = switch (os) {
        OS.android => await compileAndroidWrapper(
          native: native,
          prefix: prefix,
          libraries: libraries.values.toList(),
          output: wrapperOut,
          compiler: findAndroidNdk(
            environment: Platform.environment,
            hostOs: OS.current,
          ).linker(androidClangTriple(arch)!, _androidApi),
        ),
        OS.iOS => await compileIosWrapper(
          native: native,
          prefix: prefix,
          output: wrapperOut,
          sdk: sdk!,
          minVersion: _iosVersion,
        ),
        _ => await compileWrapper(
          native: native,
          prefix: prefix,
          output: wrapperOut,
          arch: arch == Architecture.x64 ? 'x86_64' : 'arm64',
        ),
      };
      final files = <Map<String, Object>>[];
      for (final (name, source) in [
        (wrapperName, wrapper),
        for (final MapEntry(:key, :value) in libraries.entries) (key, value),
      ]) {
        final published = 'mpx_video-$key-$name';
        final copy = File(
          source.resolveSymbolicLinksSync(),
        ).copySync('${out.path}/$published');
        final bytes = copy.readAsBytesSync();
        files.add({
          'name': name,
          'file': published,
          'sha256': sha256.convert(bytes).toString(),
          'size': bytes.length,
        });
      }
      targets[key] = files;
      final configure = File(
        '${native.path}/.build/$recipe/configure-line.txt',
      );
      if (configure.existsSync()) {
        configure.copySync('${out.path}/ffmpeg-configure-$key.txt');
      }
      stdout.writeln('$recipe: ${files.length} files as $key');
    } on Object catch (e) {
      stderr.writeln('$recipe: failed: $e');
      failed = true;
    }
  }
  final manifest = const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'sourceHash': videoSourceHash(native),
    'baseUrl': baseUrl,
    'targets': targets,
  });
  // Parsed back as the hook will: nothing it would refuse is written.
  VideoPrebuiltManifest.parse(manifest);
  File('${out.path}/prebuilts.json').writeAsStringSync('$manifest\n');
  exitCode = failed ? 1 : 0;
}
