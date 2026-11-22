import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/feature/app/view/social_app.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/initialization/initialize_dependencies.dart';

/// Initializes the app and prepares it for use.
Future<void> $initializeApp({
  FutureOr<void> Function(Dependencies dependencies)? onSuccess,
  void Function(int progress, String message)? onProgress,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  var latestProgress = 0;
  var latestStep = 'Not started';

  // Defer the first frame until everything is initialized and the app is
  // ready to be displayed.
  final binding = WidgetsFlutterBinding.ensureInitialized()..deferFirstFrame();
  try {
    // Errors the framework does not catch are logged, not fatal.
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      l.e('Top level error: $error', stackTrace);
      return true;
    };

    // Initialize the application step by step.
    final dependencies = await $initializeDependencies(
      onProgress: (progress, message) {
        latestProgress = progress;
        latestStep = message;
        onProgress?.call(progress, message);
      },
    ).timeout(const Duration(minutes: 1));

    // Allow the first frame once the app is initialized.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      binding.allowFirstFrame();
      l.i('App initialized successfully');
      onSuccess?.call(dependencies);
    });
    runApp(dependencies.inject(const SocialApp()));
  } on TimeoutException catch (error, stackTrace) {
    final timeoutError = TimeoutException(
      'Initialization timed out after '
      '${error.duration?.inSeconds ?? 0}s '
      'at step "$latestStep" ($latestProgress%). '
      'Original error: ${error.message ?? error}',
      error.duration,
    );
    binding.allowFirstFrame();
    onError?.call(timeoutError, stackTrace);
    Error.throwWithStackTrace(timeoutError, stackTrace);
  } on Object catch (error, stackTrace) {
    binding.allowFirstFrame();
    onError?.call(error, stackTrace);
    rethrow;
  }
}
