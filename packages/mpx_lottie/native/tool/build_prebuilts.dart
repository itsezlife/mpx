/// Builds the prebuilt libraries this host can build, named as
/// `assemble_manifest.dart` reads them. From the package root:
///
/// ```sh
/// dart native/tool/build_prebuilts.dart <out dir> [key,key,...]
/// ```
///
/// Each library is compiled exactly as the build hook compiles it
/// (`compileCrate`: the same cargo flags, NDK linker, 16 KB pages, header
/// check), for every published key (`LottieNativeTarget.keys`) or the keys
/// given, and copied to `<out>/libmpx_lottie-<key>.<ext>`. A key this host
/// cannot build is skipped and said so; the exit code is 1 when a key that
/// could be built failed.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';

import '../../hook/src/cargo_build.dart';
import '../../hook/src/targets.dart';

// Android and iOS prebuilts are built for the floors Flutter apps use, so one
// library serves every app.
const _androidApi = 21;
const _iosVersion = 13;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart native/tool/build_prebuilts.dart <out dir> [key,...]\n'
      '  keys: ${LottieNativeTarget.keys.join(', ')}',
    );
    exitCode = 64;
    return;
  }
  final out = Directory(args.first)..createSync(recursive: true);
  final keys = args.length > 1 ? args[1].split(',') : LottieNativeTarget.keys;
  final native = File.fromUri(Platform.script).parent.parent;
  final cargo = findCargo(environment: Platform.environment);
  var failed = false;
  for (final key in keys) {
    final published = LottieNativeTarget.fromKey(key);
    if (published == null) {
      stderr.writeln('$key: not a manifest key');
      failed = true;
      continue;
    }
    final target = LottieNativeTarget(
      published.os,
      published.arch,
      sdk: published.sdk,
      androidApi: published.os == OS.android ? _androidApi : null,
      iosVersion: published.os == OS.iOS ? _iosVersion : null,
    );
    if (!target.buildableOn(
      hostOs: OS.current,
      hostArch: Architecture.current,
      environment: Platform.environment,
    )) {
      stdout.writeln('$key: not buildable on this host, skipped');
      continue;
    }
    try {
      final library = await compileCrate(
        cargo: cargo,
        crate: native.uri,
        targetDir: native.uri.resolve('.build/prebuilts/'),
        target: target,
        environment: Platform.environment,
      );
      final extension = library.path.split('.').last;
      final copy = library.copySync(
        '${out.path}/libmpx_lottie-$key.$extension',
      );
      stdout.writeln('$key: ${copy.path} (${copy.lengthSync()} bytes)');
    } on Object catch (e) {
      stderr.writeln('$key: failed: $e');
      failed = true;
    }
  }
  exitCode = failed ? 1 : 0;
}
