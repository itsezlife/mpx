/// Builds the native reader of ranged resources
/// (`native/src/http_bytes_cache.c`) into the code asset that
/// `package:http_bytes_cache/src/native/hbc_bindings.dart` binds to.
///
/// One small C file and the platform's C toolchain (the system compiler on
/// macOS and Linux, Xcode's for iOS, the NDK's for Android): no prebuilt
/// binaries. The reader uses POSIX threads and `pread`, so Windows gets no
/// asset (with a warning) and the Dart side reports the reader unavailable.
/// Web builds ask for no code assets.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os == OS.windows) {
      stderr.writeln(
        'warning: http_bytes_cache has no native reader for Windows yet; '
        'ranged resources still work from Dart.',
      );
      return;
    }
    await CBuilder.library(
      name: 'http_bytes_cache',
      assetName: 'src/native/hbc_bindings.dart',
      sources: ['native/src/http_bytes_cache.c'],
      includes: ['native/include'],
      libraries: [if (os == OS.linux) 'pthread'],
      defines: {if (os == OS.linux || os == OS.android) '_GNU_SOURCE': null},
    ).run(input: input, output: output);
  });
}
