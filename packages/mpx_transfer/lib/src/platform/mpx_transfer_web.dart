import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// The web entry of mpx_transfer's plugin.
///
/// Empty: the web has no OS envelope, so `system` transfers run in the tab,
/// and the transfer engine is Dart on every platform.
final class MpxTransferWeb {
  MpxTransferWeb._();

  /// Called by the plugin registrant; registers nothing.
  static void registerWith(Registrar registrar) {}
}
