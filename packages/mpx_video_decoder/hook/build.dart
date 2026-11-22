/// Delivers the native library as the code asset that
/// `lib/src/native/mpx_video_symbols.dart` binds to, plus the FFmpeg shared
/// libraries it links.
///
/// Targets: macOS arm64 and x86_64, iOS arm64 (device and simulator), Android
/// arm64-v8a, armeabi-v7a and x86_64. In order (`planVideoDelivery`):
///
/// 1. the FFmpeg build the app names in its pubspec (`hooks: user_defines:
///    mpx_video_decoder: ffmpeg_build: DIR`), compiling the wrapper against
///    it: a developer's own build, so it can be tried;
/// 2. the published prebuilt (`native/prebuilts.json`), downloaded once into
///    the hook's shared cache and verified by size and SHA-256, used only
///    while its source hash matches these sources;
/// 3. a recipe build in the package (`native/.build/<target>/prefix`, or
///    `MPX_VIDEO_FFMPEG_DIR` where the hook sees the environment).
///
/// With none, no asset is emitted, the build warns, and the probe reports
/// `missingLibrary`.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'src/android_ndk.dart';
import 'src/ffmpeg_prefix.dart';
import 'src/video_prebuilts.dart';
import 'src/video_target.dart';
import 'src/wrapper_compile.dart';

/// Names the asset `package:mpx_video_decoder/src/binding/ffi/mpx_video_symbols.dart`,
/// the library URI of the file whose `@Native` functions resolve against it.
const _assetName = 'src/binding/ffi/mpx_video_symbols.dart';

/// The NDK clang that targets the app's Android architecture at its API
/// level.
String ndkClang(CodeConfig code) =>
    findAndroidNdk(
      environment: Platform.environment,
      hostOs: OS.current,
    ).linker(
      androidClangTriple(code.targetArchitecture)!,
      code.android.targetNdkApi,
    );

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final ios = code.targetOS == OS.iOS;
    final target = recipeTarget(
      code.targetOS,
      code.targetArchitecture,
      iosSdk: ios ? code.iOS.targetSdk : null,
    );
    if (target == null) {
      stderr.writeln(
        'warning: mpx_video_decoder has no native library for '
        '${code.targetOS} ${code.targetArchitecture} (built: macOS arm64 '
        'and x86_64, iOS arm64 device and simulator, Android arm64-v8a, '
        'armeabi-v7a and x86_64). No asset is bundled.',
      );
      return;
    }

    final native = Directory.fromUri(input.packageRoot.resolve('native/'));
    final userBuild = _directory(input.userDefines.path(ffmpegBuildDefine));
    final userPrefix = userBuild == null
        ? null
        : findFfmpegPrefix(
            native: Directory('${native.path}/.none'),
            target: target,
            environment: const {},
            userBuild: userBuild,
          );
    final localPrefix = findFfmpegPrefix(
      native: native,
      target: target,
      environment: Platform.environment,
    );
    final manifestFile = File('${native.path}/prebuilts.json');
    output.dependencies.addAll([
      manifestFile.uri,
      for (final path in videoSourceFiles) native.uri.resolve(path),
      // Watch the files a recipe build creates, so that building one re-runs
      // the hook (the environment variable is not trackable: `flutter clean`
      // after changing it).
      native.uri.resolve('.build/$target/prefix/include/libavcodec/avcodec.h'),
      ?userBuild?.resolve('$target/prefix/include/libavcodec/avcodec.h'),
    ]);
    final manifest = _readManifest(manifestFile);
    final List<VideoPrebuiltFile>? published;
    if (manifest == null) {
      published = null;
    } else if (manifest.sourceHash != videoSourceHash(native)) {
      stdout.writeln(
        'mpx_video_decoder: the prebuilts were built from other sources '
        'than these; not used.',
      );
      published = null;
    } else {
      published = manifest.filesFor(manifestKeyOf(target));
    }

    final steps = planVideoDelivery(
      userPrefix: userPrefix != null,
      prebuilt: published != null,
      localPrefix: localPrefix != null,
    );
    for (final step in steps) {
      final bundled = switch (step) {
        VideoDelivery.userPrefix => await _compileAgainst(
          input,
          output,
          native,
          userPrefix!,
        ),
        VideoDelivery.localPrefix => await _compileAgainst(
          input,
          output,
          native,
          localPrefix!,
        ),
        VideoDelivery.prebuilt => await _usePrebuilt(
          input,
          output,
          manifest!,
          published!,
        ),
      };
      if (bundled) return;
    }
    stderr.writeln(
      'warning: mpx_video_decoder has no native video library for $target: '
      'no usable prebuilt (see the line above, if any: a failed download is '
      'tried again after `flutter clean`) and no FFmpeg build. '
      'Build one with ${recipeCommandFor(target)}, or name a recipe build '
      'directory (<dir>/$target/prefix) in the app pubspec under hooks: '
      'user_defines: mpx_video_decoder: $ffmpegBuildDefine. No asset is '
      'bundled; video keeps its placeholder.',
    );
  });
}

/// The manifest, or null when it is absent or unreadable: a broken
/// manifest is a warning, never a failed build.
VideoPrebuiltManifest? _readManifest(File file) {
  if (!file.existsSync()) return null;
  try {
    return VideoPrebuiltManifest.parse(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('warning: mpx_video_decoder ignores prebuilts.json: $e');
    return null;
  }
}

/// Bundles the published [files], fetched into the shared cache. False when
/// they cannot be had (offline, a changed file): the next way is tried.
Future<bool> _usePrebuilt(
  BuildInput input,
  BuildOutputBuilder output,
  VideoPrebuiltManifest manifest,
  List<VideoPrebuiltFile> files,
) async {
  final result = await fetchVideoPrebuilts(
    files: files,
    urlOf: manifest.urlOf,
    // Outlives this build and is shared by every app of the machine, so a
    // library is downloaded once.
    cacheDir: Directory.fromUri(
      input.outputDirectoryShared.resolve('mpx_video_prebuilts/'),
    ),
  );
  switch (result) {
    case VideoPrebuiltsUnavailable(:final reason):
      stdout.writeln('mpx_video_decoder: prebuilt not used: $reason');
      return false;
    case VideoPrebuiltsReady(:final files):
      for (final MapEntry(key: name, value: file) in files.entries) {
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: name.startsWith('libmpx_video.')
                ? _assetName
                : 'ffmpeg/$name',
            linkMode: DynamicLoadingBundled(),
            file: file.uri,
          ),
        );
      }
      return true;
  }
}

/// Compiles the wrapper against [prefix] and bundles it with the prefix's
/// FFmpeg libraries. False when the toolchain is missing (the NDK): the
/// next way is tried.
Future<bool> _compileAgainst(
  BuildInput input,
  BuildOutputBuilder output,
  Directory native,
  Directory prefix,
) async {
  final code = input.config.code;
  final libraries = bundledLibraries(prefix, os: code.targetOS);
  // Every input as a file: a directory would miss an edit to a file in it.
  output.dependencies.addAll([for (final file in libraries.values) file.uri]);

  final out = input.outputDirectory;
  final File wrapper;
  switch (code.targetOS) {
    case OS.android:
      final String clang;
      try {
        clang = ndkClang(code);
      } on AndroidNdkUnavailable catch (e) {
        // Not a failed build: an app without the NDK cannot compile the
        // wrapper, which the message says how to fix.
        stderr.writeln('warning: $e');
        return false;
      }
      wrapper = await compileAndroidWrapper(
        native: native,
        prefix: prefix,
        libraries: libraries.values.toList(),
        output: File.fromUri(out.resolve('libmpx_video.so')),
        compiler: clang,
      );
    case OS.iOS:
      wrapper = await compileIosWrapper(
        native: native,
        prefix: prefix,
        output: File.fromUri(out.resolve('libmpx_video.dylib')),
        sdk: code.iOS.targetSdk,
        minVersion: code.iOS.targetVersion,
      );
    default:
      wrapper = await compileWrapper(
        native: native,
        prefix: prefix,
        output: File.fromUri(out.resolve('libmpx_video.dylib')),
        arch: code.targetArchitecture == Architecture.x64 ? 'x86_64' : 'arm64',
      );
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: wrapper.uri,
    ),
  );

  // The FFmpeg libraries are bundled under the names the wrapper's install
  // records (macOS) or sonames (Android) ask for. Nothing binds to them from
  // Dart.
  for (final MapEntry(key: name, value: file) in libraries.entries) {
    final copy = await file.copy(File.fromUri(out.resolve(name)).path);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ffmpeg/$name',
        linkMode: DynamicLoadingBundled(),
        file: copy.uri,
      ),
    );
  }
  return true;
}

// [uri] as a directory: the user define may be written without a trailing
// slash, and resolving against a file URI would drop its last segment.
Uri? _directory(Uri? uri) => switch (uri) {
  null => null,
  final uri when uri.path.endsWith('/') => uri,
  final uri => uri.replace(path: '${uri.path}/'),
};
