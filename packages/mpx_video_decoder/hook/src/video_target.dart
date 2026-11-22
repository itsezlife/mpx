/// Which targets the hook builds for, and the recipe's name for each.
library;

import 'package:code_assets/code_assets.dart';

/// The `TARGET` of `native/recipe/build.sh` that serves [os] on
/// [architecture]; null where no native library is built.
///
/// iOS builds arm64 for the device (`ios-arm64`) and for the Apple-silicon
/// simulator (`ios-sim-arm64`), told apart by [iosSdk]. The x86_64 simulator
/// is left out: it gets the `missingLibrary` probe result.
///
/// macOS x86_64 and Android x86_64 (emulators) are built without assembly
/// (plain C, slower); Android armv7 keeps NEON. Android x86 (32-bit) is
/// left out.
String? recipeTarget(OS os, Architecture architecture, {IOSSdk? iosSdk}) =>
    switch ((os, architecture, iosSdk)) {
      (OS.macOS, Architecture.arm64, _) => 'macos-arm64',
      (OS.macOS, Architecture.x64, _) => 'macos-x64',
      (OS.android, Architecture.arm64, _) => 'android-arm64',
      (OS.android, Architecture.arm, _) => 'android-arm',
      (OS.android, Architecture.x64, _) => 'android-x64',
      (OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS) => 'ios-arm64',
      (OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator) => 'ios-sim-arm64',
      _ => null,
    };

/// The key the prebuilt manifest names a [recipeTarget] by: the vocabulary
/// both native packages of mpx publish under (`<os>-<arch>[-simulator]`).
/// Only the simulator is spelled differently from the recipe's target.
String manifestKeyOf(String recipeTarget) => switch (recipeTarget) {
  'ios-sim-arm64' => 'ios-arm64-simulator',
  final other => other,
};

/// The prefix of the NDK's clang wrappers for an Android [architecture]
/// (`<prefix><api>-clang`), or null for one the recipe does not build.
String? androidClangTriple(Architecture architecture) => switch (architecture) {
  Architecture.arm64 => 'aarch64-linux-android',
  Architecture.arm => 'armv7a-linux-androideabi',
  Architecture.x64 => 'x86_64-linux-android',
  _ => null,
};
