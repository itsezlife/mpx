import 'package:flutter/widgets.dart';

/// Tells a camera session when the app is hidden (another app in front, the
/// home screen) and shown again, so it can let the camera go meanwhile.
///
/// Internal to the package: both sessions, the platform one and the fake,
/// release the camera on [onHide] and take it back on [onShow].
final class CameraBackground {
  /// Starts listening; without a widgets binding nothing is heard.
  CameraBackground({required VoidCallback onHide, required VoidCallback onShow})
    : _listener = _bound()
          ? AppLifecycleListener(onHide: onHide, onShow: onShow)
          : null;

  final AppLifecycleListener? _listener;

  static bool _bound() {
    try {
      WidgetsBinding.instance;
      return true;
    } on Object {
      return false;
    }
  }

  /// Whether the app is hidden now.
  static bool get isHidden {
    if (!_bound()) return false;
    return switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      _ => false,
    };
  }

  bool _disposed = false;

  /// Stops listening. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listener?.dispose();
  }
}
