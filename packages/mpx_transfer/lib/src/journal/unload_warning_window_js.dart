import 'dart:js_interop';

import 'package:mpx_transfer/src/journal/unload_warning.dart';
import 'package:web/web.dart' as web;

/// The [UnloadWarning] of a browser page: a `beforeunload` listener on
/// [target] (the window), there only while armed, that asks the browser to
/// confirm leaving.
///
/// Web only.
final class UnloadWarning$Window$JS implements UnloadWarning {
  /// A warning on [target], the page's window unless given.
  UnloadWarning$Window$JS([web.EventTarget? target])
    : _target = target ?? web.window;

  final web.EventTarget _target;
  late final JSFunction _listener = _confirm.toJS;
  bool _armed = false;

  @override
  bool get isArmed => _armed;

  @override
  void arm() {
    if (_armed) return;
    _armed = true;
    _target.addEventListener('beforeunload', _listener);
  }

  @override
  void disarm() {
    if (!_armed) return;
    _armed = false;
    _target.removeEventListener('beforeunload', _listener);
  }

  static void _confirm(web.Event event) {
    // Browsers ask the user when the event's default is prevented; older
    // ones only when its return value is set.
    event.preventDefault();
    if (event.isA<web.BeforeUnloadEvent>()) {
      (event as web.BeforeUnloadEvent).returnValue = '';
    }
  }
}
